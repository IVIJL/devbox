#!/bin/bash
set -euo pipefail

# =============================================================================
# agent-browser-broker — host-side Agent-browser session lifecycle (ADR 0010)
# =============================================================================
# Single dispatcher for `devbox agent-browser {start,stop,status}`. Holds the
# Chrome process (Host agent Chrome, ADR 0010 § Actor 1) and the in-container
# socat bridge (ADR 0010 § Actor 2) on each side of an Agent-browser session.
#
# Subcommands:
#
#   start <container>   Sweep any stale session file, then launch Chrome as
#                       `devbox-agent` on a free host loopback port, start
#                       socat inside the named container forwarding
#                       127.0.0.1:9222 -> host.docker.internal:<host-port>,
#                       and persist the session-state JSON.
#   stop <container>    Read the state JSON, kill Chrome, kill the
#                       in-container bridge, remove the state file. Safe to
#                       re-run when the state file is missing.
#   status <container>  Print the active session details (PIDs, ports,
#                       profile dir, created_at) in a readable form.
#
# Slice 02 scope:
#   - lifecycle skeleton only — no Chrome hardening flags (slice 03), no
#     forward proxy (slice 04+), no netlog archival, no toast notifications.
#
# Why this file lives in scripts/ and not lib/: per ADR 0010 References,
# `scripts/agent-browser-broker.sh` is the canonical multi-subcommand
# dispatcher; lib/ holds reusable sourced modules, scripts/ holds
# executable host-side entry points.
# =============================================================================

DEVBOX_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

# shellcheck source=../lib/host-platform.sh
source "$DEVBOX_DIR/lib/host-platform.sh"

# --- Constants ---------------------------------------------------------------

# Session state JSON lives under XDG state — survives reboots, lets us
# reconcile after a container stop or a host crash on the next `start`.
SESSIONS_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/devbox/agent-browser/sessions"

# Ephemeral Chrome profiles + downloads live under a devbox-agent-owned
# parent so the OS-identity boundary covers them too (ADR 0010 § Actor 1).
# /var/lib is the FHS-canonical location for service-owned mutable state;
# the parent dirs are created (with sudo, once) on first `start`.
AGENT_PROFILES_DIR="/var/lib/devbox-agent/profiles"
AGENT_DOWNLOADS_DIR="/var/lib/devbox-agent/downloads"

# Netlog archive dir on the host. Populated at `stop` time when the live
# netlog (under the ephemeral profile dir) is moved here for forensics.
# Owned by devbox-agent; the local developer reads via group membership
# (ADR 0010 § "Tamper-proof property").
AGENT_NETLOG_ARCHIVE_DIR="/var/log/devbox/agent-browser"

# Container-side CDP endpoint exposed by the bridge socat. Stable so the
# agent-browser CLI always sees the same URL regardless of which random
# host port Chrome chose this session. ADR 0010 § Actor 2.
BRIDGE_CONTAINER_PORT="9222"

# --- Logging -----------------------------------------------------------------

_log()  { printf '%s\n' "$*"; }
_warn() { printf '%s\n' "$*" >&2; }
_die()  { _warn "agent-browser: $*"; exit 1; }

# --- Argument helpers --------------------------------------------------------

_usage() {
    cat <<'EOF'
Usage:
  agent-browser-broker.sh start  <container>
  agent-browser-broker.sh stop   <container>
  agent-browser-broker.sh status <container>
EOF
}

# Require a name that looks like a devbox container; the broker doesn't
# resolve project-name -> container-name (that's `devbox agent-browser`
# dispatch). We just validate the input shape and check Docker.
#
# Charset enforcement mirrors Docker's own `[a-zA-Z0-9][a-zA-Z0-9_.-]*`
# regex. It's defence-in-depth: the container name flows into derived
# paths (profile dir, archive filename) and into the state-file name,
# so even though Docker would reject `../foo` upstream we still refuse
# anything we'd be embarrassed to expand into a filesystem path.
_require_container_arg() {
    local container="${1:-}"
    [ -n "$container" ] || { _usage >&2; exit 2; }
    case "$container" in
        [a-zA-Z0-9]*) ;;
        *) _die "Invalid container name '${container}': must start with [a-zA-Z0-9]." ;;
    esac
    case "$container" in
        *[!a-zA-Z0-9._-]*) _die "Invalid container name '${container}': only [a-zA-Z0-9._-] allowed." ;;
    esac
    printf '%s\n' "$container"
}

_container_running() {
    docker ps --filter "name=^${1}$" --format '{{.Names}}' | grep -q .
}

_container_exists() {
    docker ps -a --filter "name=^${1}$" --format '{{.Names}}' | grep -q .
}

# --- Session state -----------------------------------------------------------

_state_file() {
    printf '%s/%s.json\n' "$SESSIONS_DIR" "$1"
}

# Read a top-level scalar from the state JSON. Uses jq if available
# (preferred), falls back to a regex-based grep so the broker remains
# functional on minimal hosts where jq is missing — the dependency is
# documented in ADR 0010 but not yet enforced by install.sh.
_state_get() {
    local file="$1" key="$2"
    [ -f "$file" ] || return 1
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg k "$key" '.[$k] // empty' "$file"
        return 0
    fi
    # Fallback: parse "key": <value> for string or number. Numbers come
    # without quotes, strings come quoted. Both shapes captured by the
    # same expression.
    grep -oE "\"$key\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|[0-9]+|null)" "$file" \
        | head -1 \
        | sed -E "s/^\"$key\"[[:space:]]*:[[:space:]]*//; s/^\"//; s/\"$//"
}

_iso_utc_now() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# --- Free-port discovery -----------------------------------------------------

# Bind a TCP socket to port 0 and read back the kernel's assignment. Python3
# is in the devbox host install set (mkcert, dns-install both use it), so
# this is safe; the alternative `bash + /dev/tcp` cannot ask the kernel to
# pick a free port, only test specific ones.
_pick_free_port() {
    python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

# --- Detach helper -----------------------------------------------------------

# Echo the literal command used to detach a child from the broker's session.
# `setsid` is the strongest detach (new session + SIGHUP ignored) but is
# Linux-only; macOS lacks it. `nohup` alone covers the SIGHUP case, which
# is the only signal the broker's shell exit would otherwise raise on the
# child. Used as a prefix in front of the actual command.
_detach_prefix() {
    if command -v setsid >/dev/null 2>&1; then
        printf 'setsid\n'
    else
        printf 'nohup\n'
    fi
}

# --- Process liveness --------------------------------------------------------

_pid_alive_on_host() {
    local pid="${1:-}"
    [ -n "$pid" ] || return 1
    # `kill -0` returns 0 only if the caller may signal that PID — for
    # devbox-agent-owned processes from the user's shell this returns
    # EPERM (rc=1) even though the process is alive. `ps -p` checks
    # existence without permission to signal and is portable across
    # Linux and macOS. /proc/<pid> is the Linux-only third fallback,
    # useful if `ps` is missing in a minimal environment.
    if ps -p "$pid" >/dev/null 2>&1; then
        return 0
    fi
    if kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    [ -d "/proc/$pid" ]
}

# `_pid_alive_on_host` only checks existence — but PIDs are reused after
# reboot. For session-state liveness checks we additionally need to know
# the PID still belongs to the same agent-browser process we launched.
# Match against the unique --user-data-dir (Chrome) or the bind-address +
# port pair (relay) embedded in the original cmdline. Returns 0 only when
# the PID is alive AND its cmdline contains the marker.
_pid_matches_marker() {
    local pid="${1:-}" marker="${2:-}"
    [ -n "$pid" ] || return 1
    [ -n "$marker" ] || return 1
    _pid_alive_on_host "$pid" || return 1

    # /proc cmdline is NUL-separated; tr to space for grep. ps fallback
    # covers macOS where /proc doesn't exist; `ps -p` here may be limited
    # to the caller's processes for non-owned PIDs, but for our sweep
    # purposes "we can't read it" is treated as "could be ours, refuse
    # to sweep" — fail-safe.
    if [ -r "/proc/$pid/cmdline" ]; then
        tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null \
            | grep -qF -- "$marker" \
            && return 0
        return 1
    fi
    local cmdline
    cmdline="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    [ -n "$cmdline" ] || return 0
    printf '%s' "$cmdline" | grep -qF -- "$marker"
}

_pid_alive_in_container() {
    local container="$1" pid="${2:-}"
    [ -n "$pid" ] || return 1
    docker exec "$container" sh -c "[ -d /proc/$pid ]" 2>/dev/null
}

# Like _pid_matches_marker but the PID lives inside the named container.
# Used to discriminate a live bridge socat from a recycled PID across
# container restarts (PIDs reset to small values inside a fresh container).
_pid_matches_marker_in_container() {
    local container="$1" pid="${2:-}" marker="${3:-}"
    [ -n "$pid" ] || return 1
    [ -n "$marker" ] || return 1
    docker exec "$container" sh -c "
        [ -r /proc/$pid/cmdline ] || exit 1
        tr '\0' ' ' < /proc/$pid/cmdline | grep -qF -- \"\$1\"
    " _ "$marker" 2>/dev/null
}

# --- Session-dir cleanup -----------------------------------------------------

# Reject any path that doesn't sit directly under one of the agent-owned
# parents we manage. The session-state JSON lives under the developer's
# home dir and so is writable by the developer; without this guard, a
# corrupted or tampered state file could direct the subsequent `sudo rm`
# calls at any path.
#
# Acceptance rules:
#   - must start with the expected parent + exactly one basename
#     (single component, no nested subdirs)
#   - must not equal the parent itself
#   - basename charset restricted to [A-Za-z0-9._-] (matches our
#     `<container>-<ts>` build pattern)
#   - basename must not be `.` or `..` (traversal anchors)
#   - if a third arg `session_prefix` is given, the basename must
#     start with that exact string — used to bind cleanup to the
#     currently-named container, so a tampered state JSON can't
#     redirect rm/mv at a sibling session under the same parent.
#
# The full-path `..` substring check used in earlier drafts was
# overzealous: Docker names like `foo..bar` produce legitimate paths
# such as `/var/lib/devbox-agent/profiles/foo..bar-20260519T120000Z`
# that contain `..` but are not traversal attempts. Doing the check
# on the extracted basename after the single-component constraint
# already rules out real traversal.
_is_managed_path() {
    local path="${1:-}" parent="${2:-}" session_prefix="${3:-}"
    [ -n "$path" ] || return 1
    [ -n "$parent" ] || return 1
    [ "$path" != "$parent" ] || return 1
    local prefix="${parent%/}/"
    case "$path" in
        "$prefix"*) ;;
        *) return 1 ;;
    esac
    local basename="${path#"$prefix"}"
    [ -n "$basename" ] || return 1
    case "$basename" in
        */*) return 1 ;;
    esac
    [ "$basename" != "." ] || return 1
    [ "$basename" != ".." ] || return 1
    case "$basename" in
        *[!A-Za-z0-9._-]*) return 1 ;;
    esac
    if [ -n "$session_prefix" ]; then
        case "$basename" in
            "$session_prefix"*) ;;
            *) return 1 ;;
        esac
    fi
    return 0
}

# Remove the per-session profile and download dirs. Used by `cmd_start`'s
# early-failure rollback paths (before the state JSON is written, so the
# stale-session sweep on the next `start` has nothing to anchor on) and
# anywhere else that needs to scrub the dirs without going through `stop`.
# `session_prefix` (third arg, typically `${container}-`) binds the rm
# to the currently-named session — a tampered state JSON cannot direct
# the sudo rm at a sibling session's dir under the same parent.
# Existence is checked through `sudo test` because the 0700 parents block
# the developer from stat'ing into the devbox-agent-owned tree.
_cleanup_session_dirs() {
    local profile_dir="${1:-}" download_dir="${2:-}" session_prefix="${3:-}"
    if [ -n "$profile_dir" ] \
        && _is_managed_path "$profile_dir" "$AGENT_PROFILES_DIR" "$session_prefix" \
        && sudo test -d "$profile_dir"; then
        sudo rm -rf -- "$profile_dir" || _warn "Failed to remove profile dir ${profile_dir}."
    fi
    if [ -n "$download_dir" ] \
        && _is_managed_path "$download_dir" "$AGENT_DOWNLOADS_DIR" "$session_prefix" \
        && sudo test -d "$download_dir"; then
        sudo rm -rf -- "$download_dir" || _warn "Failed to remove download dir ${download_dir}."
    fi
}

# --- Sweep stale session -----------------------------------------------------

# Remove a session-state file whose Chrome and bridge are both already
# dead. Called from `start` before refusing — matches ADR 0010 "the broker
# first sweeps for orphan processes from a stale session file". Returns 0
# if a sweep was needed AND completed (state file removed), 1 if either
# process is still alive (caller should refuse).
_sweep_if_stale() {
    local container="$1"
    local file
    file="$(_state_file "$container")"
    [ -f "$file" ] || return 0

    local chrome_pid bridge_pid relay_pid profile_dir download_dir cdp_port
    chrome_pid="$(_state_get "$file" chrome_pid || true)"
    bridge_pid="$(_state_get "$file" bridge_pid_in_container || true)"
    relay_pid="$(_state_get "$file" relay_pid_host || true)"
    profile_dir="$(_state_get "$file" profile_dir || true)"
    download_dir="$(_state_get "$file" download_dir || true)"
    cdp_port="$(_state_get "$file" cdp_port_host || true)"

    # Identity markers: cmdline substrings unique to this session. PID
    # reuse after reboot would otherwise make an unrelated process look
    # like our Chrome/relay. The bridge socat inside the container is
    # also matched by cmdline via `_pid_matches_marker_in_container`.
    local chrome_marker="--user-data-dir=$profile_dir"
    local relay_marker="TCP-LISTEN:${cdp_port}"
    local bridge_marker="socat TCP-LISTEN:${BRIDGE_CONTAINER_PORT}"

    local chrome_alive=false bridge_alive=false relay_alive=false
    if [ -n "$chrome_pid" ] && _pid_matches_marker "$chrome_pid" "$chrome_marker"; then
        chrome_alive=true
    fi
    if _container_running "$container" \
        && [ -n "$bridge_pid" ] \
        && _pid_matches_marker_in_container "$container" "$bridge_pid" "$bridge_marker"; then
        bridge_alive=true
    fi
    if [ -n "$relay_pid" ] && [ "$relay_pid" != "null" ] \
        && _pid_matches_marker "$relay_pid" "$relay_marker"; then
        relay_alive=true
    fi

    if [ "$chrome_alive" = true ] || [ "$bridge_alive" = true ] || [ "$relay_alive" = true ]; then
        return 1
    fi

    _warn "Sweeping stale session file for ${container} (Chrome=${chrome_pid:-?}, bridge=${bridge_pid:-?}, relay=${relay_pid:-?} all gone or reused)."

    # Cleaning up stale session resources from the prior crash: the
    # session-scoped profile/download dirs would otherwise accumulate
    # under /var/lib/devbox-agent/ across host crashes, leaking the
    # netlog and any half-written downloads from the dead session.
    # `_is_managed_path` blocks a corrupted state file from escalating
    # the sudo rm into arbitrary deletion; `sudo test -d` is needed
    # because the 0700 parent dirs block the developer from stat'ing
    # into the devbox-agent-owned tree without elevation.
    if [ -n "$profile_dir" ] && [ "$profile_dir" != "null" ] \
        && _is_managed_path "$profile_dir" "$AGENT_PROFILES_DIR" "${container}-" \
        && sudo test -d "$profile_dir"; then
        _warn "Cleaning up stale session resources from ${profile_dir}..."
        sudo rm -rf -- "$profile_dir" || _warn "Failed to remove stale profile dir ${profile_dir}."
    fi
    if [ -n "$download_dir" ] && [ "$download_dir" != "null" ] \
        && _is_managed_path "$download_dir" "$AGENT_DOWNLOADS_DIR" "${container}-" \
        && sudo test -d "$download_dir"; then
        _warn "Cleaning up stale session resources from ${download_dir}..."
        sudo rm -rf -- "$download_dir" || _warn "Failed to remove stale download dir ${download_dir}."
    fi

    rm -f -- "$file"
    return 0
}

# --- subcommand: start -------------------------------------------------------

cmd_start() {
    local container
    container="$(_require_container_arg "${1:-}")"

    _container_exists "$container" \
        || _die "Container '${container}' does not exist. Start it first: devbox ${container#devbox-}"
    _container_running "$container" \
        || _die "Container '${container}' exists but is not running. Start it first: devbox ${container#devbox-}"

    mkdir -p "$SESSIONS_DIR"

    if ! _sweep_if_stale "$container"; then
        local file
        file="$(_state_file "$container")"
        _warn "An Agent-browser session is already active for '${container}'."
        _warn "  State file: $file"
        _warn "  Stop it first: devbox agent-browser stop ${container}"
        exit 1
    fi

    local chrome_bin
    chrome_bin="$(host_platform::chrome_binary)" \
        || _die "Chrome binary not found on host. See install instructions above."

    id devbox-agent >/dev/null 2>&1 \
        || _die "OS user 'devbox-agent' missing. Run: bash ${DEVBOX_DIR}/install.sh"

    # Profile + downloads dir, owned by devbox-agent. /var/lib/devbox-agent
    # may not exist before the first session — create it once, then chown.
    # `install -d` is the portable atomic equivalent of mkdir+chmod+chown,
    # but requires the target's parent to exist; we layer manually so the
    # first time through still works on a fresh host.
    # Trailing colon on chown = "owner's primary group", portable on Linux
    # (GNU coreutils) and macOS (BSD chown). On Linux the primary group is
    # `devbox-agent` (--user-group in lib/host-platform.sh); on macOS
    # sysadminctl assigns `staff`. Either way no extra group lookup is needed.
    local agent_parent
    for agent_parent in "$AGENT_PROFILES_DIR" "$AGENT_DOWNLOADS_DIR"; do
        if [ ! -d "$agent_parent" ]; then
            sudo mkdir -p "$agent_parent"
            sudo chown devbox-agent: "$agent_parent"
            sudo chmod 700 "$agent_parent"
        fi
    done

    # Netlog archive dir under /var/log so the developer can read past
    # sessions via group membership (parallels allow-for log layout).
    # Group-readable bit on the dir lets future slices add group provisioning
    # without revisiting this code; for slice 03 the local developer must
    # already be in the devbox-agent group to read individual files.
    if [ ! -d "$AGENT_NETLOG_ARCHIVE_DIR" ]; then
        sudo mkdir -p "$AGENT_NETLOG_ARCHIVE_DIR"
        sudo chown devbox-agent: "$AGENT_NETLOG_ARCHIVE_DIR"
        sudo chmod 750 "$AGENT_NETLOG_ARCHIVE_DIR"
    fi

    local ts profile_dir download_dir netlog_path
    ts="$(date -u +"%Y%m%dT%H%M%SZ")"
    profile_dir="${AGENT_PROFILES_DIR}/${container}-${ts}"
    download_dir="${AGENT_DOWNLOADS_DIR}/${container}-${ts}"
    # Why: `netlog_path` in the state JSON tracks the LIVE location during
    # the session; `cmd_stop` moves the file to the archive dir and the
    # state file is removed in the same step, so there is no post-archive
    # consumer of the field. Keeping it as the live path keeps the field
    # meaningful while the session is running (e.g. `status` could surface it).
    netlog_path="${profile_dir}/netlog.json"
    sudo -u devbox-agent mkdir -p "$profile_dir" "$download_dir"

    # Seed Default/Preferences with the download dir. ADR 0010 lists
    # `--download-default-directory` as the mechanism, but in practice
    # modern Chrome only consistently honours that path when it is
    # ALSO present in the profile's Preferences JSON — the CLI flag
    # alone is treated as an initial-state hint and can be overridden
    # by the embedded prefs on first run. Writing the prefs eagerly
    # closes the gap so user-initiated downloads land in the ephemeral
    # dir we delete on `stop`, instead of escaping to ~devbox-agent.
    # `prompt_for_download: false` keeps the agent from blocking on a
    # save dialog inside a CDP-driven Chrome.
    sudo -u devbox-agent mkdir -p "$profile_dir/Default"
    sudo -u devbox-agent tee "$profile_dir/Default/Preferences" >/dev/null <<EOF
{
  "download": {
    "default_directory": "${download_dir}",
    "prompt_for_download": false
  },
  "profile": {
    "default_content_setting_values": {
      "automatic_downloads": 1
    }
  }
}
EOF

    local cdp_port
    cdp_port="$(_pick_free_port)"
    [ -n "$cdp_port" ] || _die "Failed to pick a free host port for CDP."

    _log "Starting Host agent Chrome for ${container} on 127.0.0.1:${cdp_port}..."

    # Forward the caller's GUI session credentials so Chrome (running as
    # devbox-agent) can open a window on the user's display. `sudo -u`
    # would otherwise reset the environment and Chrome would fail to
    # connect to the X11/Wayland/WSLg socket.
    #
    # WSL2 + WSLg (the user's primary platform): WAYLAND_DISPLAY +
    # XDG_RUNTIME_DIR point at /mnt/wslg, world-readable by default so
    # devbox-agent can use them as-is. DISPLAY=:0 + WSLg's Xwayland
    # socket are equally accessible.
    #
    # Native Linux X11: DISPLAY + XAUTHORITY. The user's Xauthority cookie
    # must be readable by devbox-agent — outside the scope of this slice
    # to provision automatically (slice 03 hardening + install.sh sudoers
    # additions). If it isn't readable, Chrome errors out with a clear
    # X11 connection failure in chrome.stderr.log; the CDP smoke test
    # then fails and we roll back below.
    #
    # macOS Quartz: needs `open -na Chrome ... --user` or a logged-in
    # devbox-agent session; that work also lives in slice 03.
    local detach
    detach="$(_detach_prefix)"
    sudo --preserve-env=DISPLAY,XAUTHORITY,WAYLAND_DISPLAY,XDG_RUNTIME_DIR,XDG_SESSION_TYPE \
        -u devbox-agent "$detach" sh -c '
        exec "$1" \
            --remote-debugging-port="$2" \
            --remote-debugging-address=127.0.0.1 \
            --user-data-dir="$3" \
            --no-first-run \
            --no-default-browser-check \
            --disable-extensions \
            --disable-sync \
            --disable-background-networking \
            --disable-component-update \
            --disable-features=NativeMessaging,OptimizationHints,AutofillServerCommunication \
            --download-default-directory="$4" \
            --log-net-log="$5" \
            </dev/null \
            >"$3/chrome.stdout.log" \
            2>"$3/chrome.stderr.log"
    ' agent-browser-chrome "$chrome_bin" "$cdp_port" "$profile_dir" "$download_dir" "$netlog_path" &
    disown 2>/dev/null || true

    # Reconcile Chrome's actual PID via pgrep on the unique --user-data-dir
    # path. Necessary because `$!` above is the wrapping sudo/setsid/sh
    # process tree, not Chrome itself. The profile_dir is session-scoped
    # so the match is unambiguous. Loop briefly to cover Chrome's startup
    # latency (cold launch can take a second on a busy host).
    local chrome_pid="" chrome_retry
    for chrome_retry in 1 2 3 4 5 6 7 8 9 10; do
        : "$chrome_retry"
        chrome_pid="$(pgrep -f -- "--user-data-dir=$profile_dir" 2>/dev/null \
            | head -1 || true)"
        [ -n "$chrome_pid" ] && break
        sleep 0.3
    done
    if [ -z "$chrome_pid" ]; then
        _warn "Chrome failed to start. stderr:"
        # stderr log lives under the 0700 devbox-agent profile dir, so
        # the developer can't read it directly; route through sudo cat.
        sudo cat "$profile_dir/chrome.stderr.log" 2>/dev/null \
            | sed 's/^/  /' >&2 || true
        _cleanup_session_dirs "$profile_dir" "$download_dir" "${container}-"
        exit 1
    fi

    # Host-side relay. On Docker Desktop (most WSL2 setups, macOS),
    # `host.docker.internal` resolves to a magic VM-routed address that
    # Docker Desktop forwards to host loopback directly, so the in-container
    # socat reaches Chrome on 127.0.0.1:${cdp_port} with no host-side help.
    # On native Linux (and on WSL2 with Docker CE, which install.sh also
    # supports), `--add-host=...=host-gateway` resolves to a docker bridge
    # gateway IP — could be the devproxy network's gateway or, in some
    # configurations, the host's default-bridge gateway. Chrome (bound to
    # 127.0.0.1) does not accept either. A small socat relay listening on
    # exactly the IP `host.docker.internal` resolves to, forwarding to
    # 127.0.0.1, closes the gap without exposing Chrome to a routable
    # interface (those docker bridge IPs are host-private).
    #
    # Detection: ask the target container what `host.docker.internal`
    # resolves to. If the resolved IP is host-owned (we can bind to it),
    # we need the relay. On Docker Desktop the resolved IP belongs to
    # the LinuxKit VM, not the host — the socat bind will fail there and
    # we treat that as "no relay needed".
    local relay_pid=""
    local resolved_hdi
    resolved_hdi="$(docker exec "$container" \
        getent hosts host.docker.internal 2>/dev/null | awk '{print $1}' | head -1 || true)"

    if [ -n "$resolved_hdi" ] && [ "$resolved_hdi" != "127.0.0.1" ]; then
        # Host-side socat is required for the relay. On native Linux /
        # Docker-CE-under-WSL2 it's the only path that makes the in-container
        # bridge reach Chrome on loopback. Surface a clear install hint up
        # front so the user doesn't see the more confusing CDP smoke-test
        # failure later.
        if ! command -v socat >/dev/null 2>&1; then
            sudo -u devbox-agent kill "$chrome_pid" 2>/dev/null || true
            _cleanup_session_dirs "$profile_dir" "$download_dir" "${container}-"
            _die "host socat not found. Install it (Debian/Ubuntu: sudo apt-get install -y socat; Fedora/RHEL: sudo dnf install -y socat; Arch: sudo pacman -S socat; macOS: brew install socat). It is required for the Agent-browser host relay on this platform."
        fi
        _log "Starting host relay on ${resolved_hdi}:${cdp_port} -> 127.0.0.1:${cdp_port}..."

        # Same sudo + detach pattern as Chrome above: the redirects target
        # devbox-agent-owned files, so they must happen inside the sudo'd
        # shell. The bind-address restricts the listener to the docker
        # bridge interface — not LAN-reachable, not loopback-shared with
        # the user's host services.
        sudo -u devbox-agent "$detach" sh -c '
            exec socat \
                "TCP-LISTEN:$2,bind=$1,fork,reuseaddr" \
                "TCP:127.0.0.1:$2" \
                </dev/null \
                >"$3/relay.stdout.log" \
                2>"$3/relay.stderr.log"
        ' agent-browser-relay "$resolved_hdi" "$cdp_port" "$profile_dir" &
        disown 2>/dev/null || true

        local relay_retry
        for relay_retry in 1 2 3 4 5 6 7 8 9 10; do
            : "$relay_retry"
            relay_pid="$(pgrep -f -- "TCP-LISTEN:${cdp_port},bind=${resolved_hdi}" 2>/dev/null \
                | head -1 || true)"
            [ -n "$relay_pid" ] && break
            sleep 0.2
        done

        # Empty relay_pid here means socat exited within the poll window —
        # the usual cause is "address not host-owned" (Docker Desktop case).
        # That's benign: the container will reach Chrome via Docker Desktop's
        # magic forwarding. Log it and proceed without a tracked relay PID.
        if [ -z "$relay_pid" ]; then
            _log "Host relay did not bind ${resolved_hdi}:${cdp_port}; proceeding without it (Docker Desktop magic forwarding expected)."
        fi
    fi

    # In-container bridge: socat inside the container's netns, listening on
    # 127.0.0.1:9222, forwarding to host.docker.internal:<cdp_port>.
    # --add-host=host.docker.internal:host-gateway (added unconditionally
    # in docker-run.sh) makes this work on native Linux via the relay
    # above; on Docker Desktop the hostname is built-in. ADR 0010 § Actor 2.
    #
    # `docker exec -d` failures (container died between gate and exec,
    # image missing socat) must NOT escape set -e before rollback. Wrap
    # in an if/then/exit so the rollback path is reachable on every
    # failure mode below.
    _log "Starting in-container bridge: ${container}:127.0.0.1:${BRIDGE_CONTAINER_PORT} -> host.docker.internal:${cdp_port}"
    if ! docker exec -d "$container" \
        socat \
            "TCP-LISTEN:${BRIDGE_CONTAINER_PORT},bind=127.0.0.1,fork,reuseaddr" \
            "TCP:host.docker.internal:${cdp_port}"; then
        _warn "docker exec -d socat failed in ${container}; rolling back Chrome and relay."
        sudo -u devbox-agent kill "$chrome_pid" 2>/dev/null || true
        if [ -n "$relay_pid" ]; then
            sudo -u devbox-agent kill "$relay_pid" 2>/dev/null || true
        fi
        _cleanup_session_dirs "$profile_dir" "$download_dir" "${container}-"
        exit 1
    fi

    # docker exec -d returns immediately and doesn't expose the in-container
    # PID. Re-read it via pgrep once socat has had a moment to register.
    local bridge_pid="" bridge_retry
    for bridge_retry in 1 2 3 4 5; do
        : "$bridge_retry"
        bridge_pid="$(docker exec "$container" \
            pgrep -nf "socat TCP-LISTEN:${BRIDGE_CONTAINER_PORT}" 2>/dev/null || true)"
        [ -n "$bridge_pid" ] && break
        sleep 0.2
    done
    if [ -z "$bridge_pid" ]; then
        _warn "Bridge socat did not register inside ${container}; rolling back Chrome and relay."
        sudo -u devbox-agent kill "$chrome_pid" 2>/dev/null || true
        if [ -n "$relay_pid" ]; then
            sudo -u devbox-agent kill "$relay_pid" 2>/dev/null || true
        fi
        _cleanup_session_dirs "$profile_dir" "$download_dir" "${container}-"
        exit 1
    fi

    local created_at
    created_at="$(_iso_utc_now)"

    # Write state JSON. Fields that this slice doesn't use yet (proxy_pid,
    # proxy_port_host, netlog_path, active_network_window) are emitted as
    # null per the ADR's example shape, so later slices can populate them
    # in-place without breaking readers. `relay_pid_host` is an addition
    # over the ADR's listed shape — host-side relay PID for native Linux
    # only; null elsewhere — needed so `stop` can clean it up.
    local relay_pid_json="null"
    [ -n "$relay_pid" ] && relay_pid_json="$relay_pid"
    local state_file
    state_file="$(_state_file "$container")"
    cat > "$state_file" <<EOF
{
  "container": "${container}",
  "chrome_pid": ${chrome_pid},
  "bridge_pid_in_container": ${bridge_pid},
  "relay_pid_host": ${relay_pid_json},
  "proxy_pid": null,
  "cdp_port_host": ${cdp_port},
  "proxy_port_host": null,
  "profile_dir": "${profile_dir}",
  "download_dir": "${download_dir}",
  "netlog_path": "${netlog_path}",
  "created_at": "${created_at}",
  "active_network_window": null
}
EOF

    # End-to-end smoke test of the CDP path from inside the container.
    # Chrome's CDP HTTP listener is ready a few moments after process
    # spawn; poll for up to ~3s so we don't false-positive on a slow
    # cold start. This is acceptance criterion #3 and the most reliable
    # way to detect both relay misconfig (host.docker.internal pointing
    # to a non-host-owned IP without Docker Desktop magic) and Chrome
    # CDP listener bring-up failures.
    local cdp_check=""
    local cdp_retry
    for cdp_retry in 1 2 3 4 5 6 7 8 9 10; do
        : "$cdp_retry"
        if cdp_check="$(docker exec "$container" \
            curl -sf --max-time 1 "http://127.0.0.1:${BRIDGE_CONTAINER_PORT}/json/version" 2>/dev/null)" \
            && [ -n "$cdp_check" ]; then
            break
        fi
        cdp_check=""
        sleep 0.3
    done

    # CDP unreachable means the session is unusable. Tear down everything
    # we started and surface a clear error rather than leaving the user
    # with a half-broken session whose `status` reports "alive".
    if [ -z "$cdp_check" ]; then
        _warn "CDP NOT reachable from inside ${container}:127.0.0.1:${BRIDGE_CONTAINER_PORT}."
        _warn "  Rolling back the session (Chrome, relay, bridge)."
        _warn "  Diagnose with:"
        _warn "    docker exec ${container} curl -v http://127.0.0.1:${BRIDGE_CONTAINER_PORT}/json/version"
        _warn "    docker exec ${container} getent hosts host.docker.internal"
        # Inline rollback: cmd_stop expects the state file to exist; we
        # just wrote it, so delegate to it for the heavy lifting (kill
        # the three processes, remove the state file).
        cmd_stop "$container"
        exit 1
    fi

    _log "Agent-browser session started."
    _log "  Chrome PID (host):         ${chrome_pid}"
    [ -n "$relay_pid" ] && _log "  Relay PID (host):          ${relay_pid}"
    _log "  Bridge PID (in container): ${bridge_pid}"
    _log "  CDP (host):                127.0.0.1:${cdp_port}"
    _log "  CDP (in container):        127.0.0.1:${BRIDGE_CONTAINER_PORT}"
    _log "  Profile dir:               ${profile_dir}"
    _log "  State:                     ${state_file}"
    _log "  CDP reachable from container: yes"
}

# --- subcommand: stop --------------------------------------------------------

cmd_stop() {
    local container
    container="$(_require_container_arg "${1:-}")"

    local state_file
    state_file="$(_state_file "$container")"

    if [ ! -f "$state_file" ]; then
        _log "No Agent-browser session for ${container} (idempotent no-op)."
        return 0
    fi

    local chrome_pid bridge_pid relay_pid profile_dir download_dir netlog_path cdp_port
    chrome_pid="$(_state_get "$state_file" chrome_pid || true)"
    bridge_pid="$(_state_get "$state_file" bridge_pid_in_container || true)"
    relay_pid="$(_state_get "$state_file" relay_pid_host || true)"
    profile_dir="$(_state_get "$state_file" profile_dir || true)"
    download_dir="$(_state_get "$state_file" download_dir || true)"
    netlog_path="$(_state_get "$state_file" netlog_path || true)"
    cdp_port="$(_state_get "$state_file" cdp_port_host || true)"

    local chrome_marker="--user-data-dir=$profile_dir"
    local relay_marker="TCP-LISTEN:${cdp_port}"
    local bridge_marker="socat TCP-LISTEN:${BRIDGE_CONTAINER_PORT}"

    # All kill paths gate on the marker match, not bare PID existence —
    # if a saved PID has been reused by an unrelated process across a
    # reboot, we must not signal it.
    if [ -n "$chrome_pid" ] && _pid_matches_marker "$chrome_pid" "$chrome_marker"; then
        _log "Stopping Chrome PID ${chrome_pid}..."
        # devbox-agent owns the process; the invoking user generally can't
        # signal directly. Use sudo to send SIGTERM, then a SIGKILL fallback
        # if Chrome doesn't exit promptly. kill exit-code is ignored — the
        # liveness re-check below is the authoritative answer.
        sudo -u devbox-agent kill "$chrome_pid" 2>/dev/null || true
        local term_wait
        for term_wait in 1 2 3 4 5 6 7 8 9 10; do
            : "$term_wait"
            _pid_matches_marker "$chrome_pid" "$chrome_marker" || break
            sleep 0.3
        done
        if _pid_matches_marker "$chrome_pid" "$chrome_marker"; then
            _warn "Chrome did not exit on SIGTERM, sending SIGKILL."
            sudo -u devbox-agent kill -9 "$chrome_pid" 2>/dev/null || true
        fi
    else
        _log "Chrome PID ${chrome_pid:-?} already gone or reused."
    fi

    if [ -n "$relay_pid" ] && [ "$relay_pid" != "null" ] \
        && _pid_matches_marker "$relay_pid" "$relay_marker"; then
        _log "Stopping host relay PID ${relay_pid}..."
        sudo -u devbox-agent kill "$relay_pid" 2>/dev/null || true
    fi

    if _container_running "$container" \
        && [ -n "$bridge_pid" ] \
        && _pid_matches_marker_in_container "$container" "$bridge_pid" "$bridge_marker"; then
        _log "Stopping in-container bridge PID ${bridge_pid} in ${container}..."
        docker exec "$container" kill "$bridge_pid" 2>/dev/null || true
    else
        _log "Bridge PID ${bridge_pid:-?} already gone, reused, or container stopped."
    fi

    # Archive netlog before removing the profile dir. Extract the ISO
    # timestamp from the profile dir's basename (suffix after the
    # container name) so the archived filename is anchored to the
    # session that produced it. Fall back to "now" if for any reason
    # the suffix can't be parsed — the moved file is still the same
    # bytes, only the filename suffix differs.
    #
    # The `netlog_path` is sourced from a developer-writable state JSON,
    # so it MUST live under the managed profile dir — otherwise the sudo
    # mv could be redirected. Same parent check is applied to profile_dir
    # itself, plus an inside-parent constraint on netlog_path against the
    # corresponding profile_dir. Existence tests use `sudo test` because
    # the 0700 parent blocks the developer from stat'ing through it.
    local netlog_is_managed=false
    if [ -n "$netlog_path" ] && [ "$netlog_path" != "null" ] \
        && [ -n "$profile_dir" ] && [ "$profile_dir" != "null" ] \
        && _is_managed_path "$profile_dir" "$AGENT_PROFILES_DIR" "${container}-" \
        && _is_managed_path "$netlog_path" "$profile_dir"; then
        netlog_is_managed=true
    fi
    if [ "$netlog_is_managed" = true ] && sudo test -f "$netlog_path"; then
        if [ ! -d "$AGENT_NETLOG_ARCHIVE_DIR" ]; then
            sudo mkdir -p "$AGENT_NETLOG_ARCHIVE_DIR"
            sudo chown devbox-agent: "$AGENT_NETLOG_ARCHIVE_DIR"
            sudo chmod 750 "$AGENT_NETLOG_ARCHIVE_DIR"
        fi
        local ts_suffix archive_path
        ts_suffix="${profile_dir##*/"${container}"-}"
        [ "$ts_suffix" = "$profile_dir" ] && ts_suffix=""
        [ -n "$ts_suffix" ] || ts_suffix="$(date -u +"%Y%m%dT%H%M%SZ")"
        # Final defence: the archive target must itself live under the
        # archive dir and its basename must start with `${container}-`,
        # protecting against a state file with crafted whitespace or path
        # separators in container/ts that survived earlier checks.
        archive_path="${AGENT_NETLOG_ARCHIVE_DIR}/${container}-${ts_suffix}.netlog.json"
        if _is_managed_path "$archive_path" "$AGENT_NETLOG_ARCHIVE_DIR" "${container}-"; then
            if sudo mv -- "$netlog_path" "$archive_path" 2>/dev/null; then
                sudo chown devbox-agent: "$archive_path" 2>/dev/null || true
                sudo chmod 640 "$archive_path" 2>/dev/null || true
                _log "Archived netlog: ${archive_path}"
            else
                _warn "Failed to archive netlog from ${netlog_path} to ${archive_path}."
            fi
        else
            _warn "Refusing to archive netlog to suspicious path ${archive_path}."
        fi
    elif [ -n "$netlog_path" ] && [ "$netlog_path" != "null" ] && [ "$netlog_is_managed" != true ]; then
        _warn "State netlog_path '${netlog_path}' is outside the managed profile dir; skipping archive."
    fi

    # Remove the ephemeral profile and download dirs — they are session-
    # scoped per ADR 0010 § Actor 1, and any forensic value has already
    # been captured by the archived netlog above. Each path is validated
    # against its managed parent AND the `${container}-` session prefix
    # so a tampered state JSON cannot redirect rm at a sibling session.
    if [ -n "$profile_dir" ] && [ "$profile_dir" != "null" ] \
        && _is_managed_path "$profile_dir" "$AGENT_PROFILES_DIR" "${container}-" \
        && sudo test -d "$profile_dir"; then
        sudo rm -rf -- "$profile_dir" || _warn "Failed to remove profile dir ${profile_dir}."
        _log "Removed profile dir ${profile_dir}."
    elif [ -n "$profile_dir" ] && [ "$profile_dir" != "null" ]; then
        _warn "State profile_dir '${profile_dir}' is outside the managed parent or session; skipping rm."
    fi
    if [ -n "$download_dir" ] && [ "$download_dir" != "null" ] \
        && _is_managed_path "$download_dir" "$AGENT_DOWNLOADS_DIR" "${container}-" \
        && sudo test -d "$download_dir"; then
        sudo rm -rf -- "$download_dir" || _warn "Failed to remove download dir ${download_dir}."
        _log "Removed download dir ${download_dir}."
    elif [ -n "$download_dir" ] && [ "$download_dir" != "null" ]; then
        _warn "State download_dir '${download_dir}' is outside the managed parent or session; skipping rm."
    fi

    rm -f -- "$state_file"
    _log "Removed state file ${state_file}."
}

# --- subcommand: status ------------------------------------------------------

cmd_status() {
    local container
    container="$(_require_container_arg "${1:-}")"

    local state_file
    state_file="$(_state_file "$container")"

    if [ ! -f "$state_file" ]; then
        _log "No Agent-browser session for ${container}."
        return 0
    fi

    local chrome_pid bridge_pid relay_pid cdp_port profile_dir created_at
    chrome_pid="$(_state_get "$state_file" chrome_pid || true)"
    bridge_pid="$(_state_get "$state_file" bridge_pid_in_container || true)"
    relay_pid="$(_state_get "$state_file" relay_pid_host || true)"
    cdp_port="$(_state_get "$state_file" cdp_port_host || true)"
    profile_dir="$(_state_get "$state_file" profile_dir || true)"
    created_at="$(_state_get "$state_file" created_at || true)"

    local chrome_marker="--user-data-dir=$profile_dir"
    local relay_marker="TCP-LISTEN:${cdp_port}"
    local bridge_marker="socat TCP-LISTEN:${BRIDGE_CONTAINER_PORT}"

    local chrome_status="dead"
    if [ -n "$chrome_pid" ] && _pid_matches_marker "$chrome_pid" "$chrome_marker"; then
        chrome_status="alive"
    fi
    local bridge_status="dead"
    if _container_running "$container" \
        && [ -n "$bridge_pid" ] \
        && _pid_matches_marker_in_container "$container" "$bridge_pid" "$bridge_marker"; then
        bridge_status="alive"
    fi
    local relay_line=""
    if [ -n "$relay_pid" ] && [ "$relay_pid" != "null" ]; then
        local relay_status="dead"
        _pid_matches_marker "$relay_pid" "$relay_marker" && relay_status="alive"
        relay_line="  Relay PID (host):          ${relay_pid} (${relay_status})"
    fi

    cat <<EOF
Agent-browser session for ${container}:
  Created at:                ${created_at:-?}
  Chrome PID (host):         ${chrome_pid:-?} (${chrome_status})
EOF
    [ -n "$relay_line" ] && printf '%s\n' "$relay_line"
    cat <<EOF
  Bridge PID (in container): ${bridge_pid:-?} (${bridge_status})
  CDP (host):                127.0.0.1:${cdp_port:-?}
  CDP (in container):        127.0.0.1:${BRIDGE_CONTAINER_PORT}
  Profile dir:               ${profile_dir:-?}
  State file:                ${state_file}
EOF
}

# --- Dispatch ----------------------------------------------------------------

main() {
    local sub="${1:-}"
    [ -n "$sub" ] || { _usage >&2; exit 2; }
    shift
    case "$sub" in
        start)  cmd_start  "$@" ;;
        stop)   cmd_stop   "$@" ;;
        status) cmd_status "$@" ;;
        -h|--help|help) _usage ;;
        *) _usage >&2; exit 2 ;;
    esac
}

main "$@"
