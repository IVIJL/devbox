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

# shellcheck source-path=SCRIPTDIR source=../lib/host-platform.sh disable=SC1091
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
# (ADR 0010 § "Tamper-proof property"). The same dir holds the archived
# proxy-decision JSONL (slice 04 onwards).
AGENT_NETLOG_ARCHIVE_DIR="/var/log/devbox/agent-browser"

# Per-user agent-browser state root. The proxy daemon's active-mode file
# lives here. The proxy itself runs as devbox-agent and reads files via
# that OS identity, so paths must be reachable for that user (see
# `_stage_allowlist` below for the allowlist-specific handling).
AGENT_USER_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/devbox/agent-browser"
AGENT_PROXY_STATE_DIR="${AGENT_USER_STATE_DIR}/proxy"
AGENT_PROXY_MODE_FILE="${AGENT_PROXY_STATE_DIR}/active-mode"

# Host-user-owned hand-off dir for agent-browser toast events (slice 08).
# Lives under XDG_STATE so no install-time provisioning is needed and the
# broker (running as the developer) can write without sudo. The matching
# deliver-allow-for-notification.sh sweeps this dir alongside the
# allow-for one. Kept separate so the deliver script can apply
# event-type-specific reconstruction rules without disturbing the
# allow-for path.
AGENT_PENDING_DIR="${AGENT_USER_STATE_DIR}/pending"

# Path to the notification deliver script. Best-effort spawn on each
# event emit — failure to dispatch never blocks the broker's stop or
# window-close paths.
AGENT_DELIVER_BIN="${DEVBOX_DIR}/scripts/deliver-allow-for-notification.sh"

# Upper bound on `allow-for <minutes>`. 1440 = 24h matches the spirit
# of the firewall `allow-for` cap (which has no explicit cap; this is
# defence-in-depth against a typo opening a multi-day window).
AGENT_ALLOW_FOR_MAX_MINUTES=1440

# The user-facing allowlist. The proxy never reads this path directly —
# on hosts where $HOME or ~/.config is 0700, devbox-agent can't traverse
# into it. Instead, `_stage_allowlist` snapshots this file into the
# session-scoped profile dir (devbox-agent-owned) at session start, and
# the proxy is pointed at the snapshot. Hot-reload of the user's edits
# is still possible through `devbox agent-browser allow-for` (slice 05),
# which will re-stage the snapshot and SIGHUP the proxy. For slice 04
# the user edits + restarts the session, which is acceptable because
# the user has no way yet to flip the mode at runtime anyway.
AGENT_ALLOWLIST_PATH="${XDG_CONFIG_HOME:-$HOME/.config}/devbox/agent-browser-allowed-domains.conf"

# Bypass list applied on the Chrome side. Chrome routes these direct and
# the proxy never sees the requests. The set mirrors devbox's dev URL
# scheme (ADR 0007 + the wildcard rules in user CLAUDE.md).
AGENT_PROXY_BYPASS_LIST="127.0.0.1;localhost;*.test;*.127.0.0.1.sslip.io"

# Path to the proxy daemon. install.sh stages a root-owned copy under
# /usr/local/lib/devbox/agent-browser/ so the devbox-agent user can exec
# it regardless of the developer's $HOME perms (0700/0750 homes block
# traversal into the repo checkout). Override via env var for development
# against an unstaged checkout.
AGENT_HELPERS_STAGE_DIR="/usr/local/lib/devbox/agent-browser"
AGENT_PROXY_BIN="${DEVBOX_AGENT_PROXY_BIN:-${AGENT_HELPERS_STAGE_DIR}/agent-browser-proxy.py}"

# Path to the summary generator. Same staging rationale as AGENT_PROXY_BIN.
AGENT_SUMMARIZE_BIN="${DEVBOX_AGENT_SUMMARIZE_BIN:-${AGENT_HELPERS_STAGE_DIR}/agent-browser-summarize.py}"

# Chrome-death watchdog (poll Chrome PID; on exit, invoke broker stop).
# Lives next to the broker in the same scripts/ dir; we point at the
# repo copy because the broker itself runs from the same dir (DEVBOX_DIR
# resolved above via readlink -f on $0). The broker-self path is what
# the watchdog re-invokes with `stop`.
AGENT_WATCHDOG_SCRIPT="${DEVBOX_DIR}/scripts/agent-browser-watchdog.sh"
AGENT_BROKER_SELF="${DEVBOX_DIR}/scripts/agent-browser-broker.sh"
AGENT_WATCHDOG_INTERVAL_DEFAULT=10

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
  agent-browser-broker.sh start      <container>
  agent-browser-broker.sh stop       <container>
  agent-browser-broker.sh status     <container>
  agent-browser-broker.sh open       <container> <url> [<url>...]
  agent-browser-broker.sh allow-for  <minutes> <container>
  agent-browser-broker.sh allow-for  --stop    <container>
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

# Add N minutes to "now" and emit an ISO-8601 UTC timestamp. Used to
# compute the network window's `expires_at`. `date -u -d "+Nmin"` is
# GNU coreutils; macOS `date` uses `-v +Nm`. Both shapes are tried so
# the broker stays portable to macOS hosts (ADR 0010 cross-platform
# parity).
_iso_plus_minutes_utc() {
    local minutes="$1"
    local out=""
    out="$(date -u -d "+${minutes} minutes" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || true)"
    if [ -z "$out" ]; then
        out="$(date -u -v "+${minutes}M" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || true)"
    fi
    [ -n "$out" ] || return 1
    printf '%s\n' "$out"
}

# Render an ISO-8601 UTC timestamp in the user's local timezone in
# `HH:MM:SS` form. Used for the human-facing confirmation lines. Best-
# effort — on a `date` that can't parse the input, falls back to the
# original UTC string so the message still carries useful information.
_local_hms() {
    local iso="$1" out=""
    out="$(date -d "$iso" +"%H:%M:%S" 2>/dev/null || true)"
    if [ -z "$out" ]; then
        out="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +"%H:%M:%S" 2>/dev/null || true)"
    fi
    [ -n "$out" ] || out="$iso"
    printf '%s\n' "$out"
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

# --- Proxy provisioning ------------------------------------------------------

# Ensure the per-user proxy state dir exists and the canonical
# active-mode file is seeded with `default`. This is the user-visible
# source of truth that slice 05's `allow-for` will rewrite; it is NOT
# what the proxy reads at runtime (the proxy reads a staged copy under
# the devbox-agent-owned profile dir, see `_stage_proxy_inputs` below).
# Idempotent.
_ensure_proxy_user_state() {
    mkdir -p "$AGENT_PROXY_STATE_DIR"
    chmod 700 "$AGENT_PROXY_STATE_DIR" 2>/dev/null || true
    printf 'default\n' > "$AGENT_PROXY_MODE_FILE"
    chmod 600 "$AGENT_PROXY_MODE_FILE" 2>/dev/null || true
}

# Stage the allowlist and mode file into the session-scoped profile dir
# so the proxy (running as devbox-agent) can read them regardless of the
# developer's home / ~/.config permission bits.
#
# Without this snapshot the proxy fails open on a 0700 home: it cannot
# even traverse to ~/.config and treats the missing file as "empty
# allowlist" — default mode then denies everything, even what the user
# explicitly listed. Snapshotting at session start sidesteps the
# permissions question entirely.
#
# The snapshot is short-lived (session-scoped) and disposed at `stop`
# alongside the profile dir. Slice 05's `allow-for` will re-stage and
# SIGHUP the proxy.
_stage_proxy_inputs() {
    local profile_dir="$1"
    [ -n "$profile_dir" ] || return 1
    local staged_allowlist="${profile_dir}/allowed-domains.conf"
    local staged_mode="${profile_dir}/active-mode"

    # The proxy must always get a readable allowlist + mode file, even
    # when the user's allowlist is missing — an empty allowlist + default
    # mode is the correct default-deny posture.
    #
    # We touch as devbox-agent first (creating the 640 files in the 0700
    # profile dir), then pipe the user-side allowlist contents through
    # `sudo tee` so the source is read as the invoking user (who owns
    # ~/.config/devbox/...) and the destination is written as devbox-
    # agent. This sidesteps SC2024: `sudo -u ... tee dest <src` would
    # do the source-read in the invoking shell anyway, but the linter
    # warns about it because the redirect could mislead the reader.
    sudo -u devbox-agent install -m 640 /dev/null "$staged_allowlist"
    if [ -r "$AGENT_ALLOWLIST_PATH" ]; then
        cat -- "$AGENT_ALLOWLIST_PATH" \
            | sudo -u devbox-agent tee "$staged_allowlist" >/dev/null
        sudo -u devbox-agent chmod 640 "$staged_allowlist" 2>/dev/null || true
    fi

    sudo -u devbox-agent install -m 640 /dev/null "$staged_mode"
    printf 'default\n' \
        | sudo -u devbox-agent tee "$staged_mode" >/dev/null
    sudo -u devbox-agent chmod 640 "$staged_mode" 2>/dev/null || true
}

# Launch the forward proxy as `devbox-agent`. Echoes "<pid>" on success,
# returns non-zero if the proxy fails to come up within ~3s.
_start_proxy() {
    local profile_dir="$1" proxy_port="$2"
    [ -n "$profile_dir" ] || return 1
    [ -n "$proxy_port" ] || return 1
    [ -x "$AGENT_PROXY_BIN" ] || _die "agent-browser-proxy.py not executable at ${AGENT_PROXY_BIN}."
    local proxy_log_live="${profile_dir}/proxy.log"
    local staged_allowlist="${profile_dir}/allowed-domains.conf"
    local staged_mode="${profile_dir}/active-mode"

    # devbox-agent must own the live log file (the in-container `node`
    # user has no path to it; see ADR 0010 § Tamper-proof property).
    sudo -u devbox-agent touch "$proxy_log_live"
    sudo -u devbox-agent chmod 640 "$proxy_log_live" 2>/dev/null || true

    local detach
    detach="$(_detach_prefix)"
    sudo -u devbox-agent "$detach" sh -c '
        exec "$1" \
            --listen "127.0.0.1:$2" \
            --allowlist "$3" \
            --mode-file "$4" \
            --log "$5" \
            </dev/null \
            >"$6/proxy.stdout.log" \
            2>"$6/proxy.stderr.log"
    ' agent-browser-proxy "$AGENT_PROXY_BIN" "$proxy_port" "$staged_allowlist" "$staged_mode" "$proxy_log_live" "$profile_dir" &
    disown 2>/dev/null || true

    # Reconcile PID via the unique listen-port arg in cmdline. The marker
    # mirrors the Chrome/relay reconciliation pattern.
    local proxy_pid="" proxy_retry
    local marker="--listen 127.0.0.1:${proxy_port}"
    for proxy_retry in 1 2 3 4 5 6 7 8 9 10; do
        : "$proxy_retry"
        proxy_pid="$(pgrep -f -- "$marker" 2>/dev/null | head -1 || true)"
        if [ -n "$proxy_pid" ] && _pid_alive_on_host "$proxy_pid"; then
            break
        fi
        proxy_pid=""
        sleep 0.2
    done
    [ -n "$proxy_pid" ] || return 1
    printf '%s\n' "$proxy_pid"
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

    local chrome_pid bridge_pid relay_pid proxy_pid watchdog_pid profile_dir download_dir cdp_port proxy_port host_allow_ip container_name
    chrome_pid="$(_state_get "$file" chrome_pid || true)"
    bridge_pid="$(_state_get "$file" bridge_pid_in_container || true)"
    relay_pid="$(_state_get "$file" relay_pid_host || true)"
    proxy_pid="$(_state_get "$file" proxy_pid || true)"
    watchdog_pid="$(_state_get "$file" watchdog_pid || true)"
    profile_dir="$(_state_get "$file" profile_dir || true)"
    download_dir="$(_state_get "$file" download_dir || true)"
    cdp_port="$(_state_get "$file" cdp_port_host || true)"
    proxy_port="$(_state_get "$file" proxy_port_host || true)"
    host_allow_ip="$(_state_get "$file" host_allow_ip || true)"
    container_name="$(_state_get "$file" container || true)"
    [ -n "$container_name" ] || container_name="$container"

    # Identity markers: cmdline substrings unique to this session. PID
    # reuse after reboot would otherwise make an unrelated process look
    # like our Chrome/relay/proxy. The bridge socat inside the container
    # is matched by cmdline via `_pid_matches_marker_in_container`.
    local chrome_marker="--user-data-dir=$profile_dir"
    local relay_marker="TCP-LISTEN:${cdp_port}"
    local bridge_marker="socat TCP-LISTEN:${BRIDGE_CONTAINER_PORT}"
    local proxy_marker="--listen 127.0.0.1:${proxy_port}"
    local watchdog_marker="agent-browser-watchdog.sh $container_name"

    local chrome_alive=false bridge_alive=false relay_alive=false proxy_alive=false watchdog_alive=false
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
    if [ -n "$proxy_pid" ] && [ "$proxy_pid" != "null" ] \
        && [ -n "$proxy_port" ] && [ "$proxy_port" != "null" ] \
        && _pid_matches_marker "$proxy_pid" "$proxy_marker"; then
        proxy_alive=true
    fi
    if [ -n "$watchdog_pid" ] && [ "$watchdog_pid" != "null" ] \
        && _pid_matches_marker "$watchdog_pid" "$watchdog_marker"; then
        watchdog_alive=true
    fi

    if [ "$chrome_alive" = true ] || [ "$bridge_alive" = true ] \
        || [ "$relay_alive" = true ] || [ "$proxy_alive" = true ] \
        || [ "$watchdog_alive" = true ]; then
        return 1
    fi

    _warn "Sweeping stale session file for ${container} (Chrome=${chrome_pid:-?}, bridge=${bridge_pid:-?}, relay=${relay_pid:-?}, proxy=${proxy_pid:-?}, watchdog=${watchdog_pid:-?} all gone or reused)."

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

    # Close any container-side firewall slot the crashed session left
    # behind. The next start picks a fresh random CDP port, so without
    # this the old ACCEPT for `host_allow_ip:cdp_port` would linger
    # until a container restart (init-firewall flushes iptables on
    # boot). The stop helper is idempotent — a no-op if the rule is
    # already gone, harmless if the container restarted between crash
    # and sweep.
    if [ -n "$host_allow_ip" ] && [ "$host_allow_ip" != "null" ] \
        && [ -n "$cdp_port" ] && [ "$cdp_port" != "null" ] \
        && _container_running "$container"; then
        _warn "Releasing stale container firewall slot for ${host_allow_ip}:${cdp_port}..."
        docker exec -u root "$container" \
            /usr/local/bin/stop-agent-browser-host-allow "$host_allow_ip" "$cdp_port" 2>/dev/null || true
    fi

    # Watchdog log + pidfile cleanup. Same SESSIONS_DIR sibling layout
    # cmd_stop uses; harmless if the prior session never wrote them.
    rm -f -- "$SESSIONS_DIR/${container}.watchdog.pid" \
             "$SESSIONS_DIR/${container}.watchdog.log" 2>/dev/null || true

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

    # Provision per-user proxy state + start the forward proxy before
    # Chrome, so the Chrome `--proxy-server=http://127.0.0.1:<proxy_port>`
    # flag points at a listener that already exists. ADR 0010 § Actor 3.
    _ensure_proxy_user_state
    _stage_proxy_inputs "$profile_dir"
    local proxy_port proxy_pid proxy_log_live
    proxy_port="$(_pick_free_port)"
    [ -n "$proxy_port" ] || _die "Failed to pick a free host port for the proxy."
    proxy_log_live="${profile_dir}/proxy.log"

    _log "Starting Agent-browser proxy on 127.0.0.1:${proxy_port}..."
    if ! proxy_pid="$(_start_proxy "$profile_dir" "$proxy_port")"; then
        _warn "Agent-browser proxy failed to start. stderr:"
        sudo cat "${profile_dir}/proxy.stderr.log" 2>/dev/null \
            | sed 's/^/  /' >&2 || true
        _cleanup_session_dirs "$profile_dir" "$download_dir" "${container}-"
        exit 1
    fi

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
            --proxy-server="http://127.0.0.1:$6" \
            --proxy-bypass-list="$7" \
            --test-type \
            </dev/null \
            >"$3/chrome.stdout.log" \
            2>"$3/chrome.stderr.log"
    ' agent-browser-chrome "$chrome_bin" "$cdp_port" "$profile_dir" "$download_dir" "$netlog_path" "$proxy_port" "$AGENT_PROXY_BYPASS_LIST" &
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
        sudo -u devbox-agent kill "$proxy_pid" 2>/dev/null || true
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
    # `getent ahostsv4` (vs `getent hosts`) forces IPv4-only resolution. On
    # Docker Desktop dual-stack setups host.docker.internal carries both an
    # IPv4 (192.168.65.254) and an IPv6 ULA; glibc per RFC 6724 returns the
    # IPv6 first, but Docker Desktop only forwards the IPv4 magic IP, the
    # in-container bridge below uses `TCP4:`, and the firewall slot helper
    # rejects anything that isn't dotted IPv4. Pinning to v4 here keeps all
    # three consumers (relay bind, firewall ACCEPT, socat upstream) on the
    # same address.
    resolved_hdi="$(docker exec "$container" \
        getent ahostsv4 host.docker.internal 2>/dev/null | awk '{print $1}' | head -1 || true)"

    if [ -n "$resolved_hdi" ] && [ "$resolved_hdi" != "127.0.0.1" ]; then
        # Host-side socat is required for the relay. On native Linux /
        # Docker-CE-under-WSL2 it's the only path that makes the in-container
        # bridge reach Chrome on loopback. Surface a clear install hint up
        # front so the user doesn't see the more confusing CDP smoke-test
        # failure later.
        if ! command -v socat >/dev/null 2>&1; then
            sudo -u devbox-agent kill "$chrome_pid" 2>/dev/null || true
            sudo -u devbox-agent kill "$proxy_pid" 2>/dev/null || true
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

    # Container-side firewall slot for the CDP target IP+port. ADR 0001's
    # default-deny OUTPUT chain only accepts traffic to 172.18.0.0/24 (the
    # Docker bridge subnet) and the DNS-driven allowed-domains ipset. On
    # Docker Desktop, host.docker.internal resolves to 192.168.65.254 — a
    # magic IP outside both — so the in-container socat bridge below would
    # hit "No route to host" (ICMP admin-prohibited rendered as
    # EHOSTUNREACH) and the CDP smoke test would time out. Open a
    # session-scoped exception mirroring the allow-for window pattern
    # (start-allow-for-window.sh): insert ACCEPT for tcp/$cdp_port to
    # $resolved_hdi just before the final OUTPUT REJECT, and remove it in
    # cmd_stop / on rollback. Scoping to a single TCP port keeps the hole
    # as narrow as the bridge needs — arbitrary host services on the same
    # magic IP remain firewalled. On native Linux this is a no-op
    # redundancy — resolved_hdi is the bridge gateway, already covered by
    # the 172.18.0.0/24 ACCEPT — but the rule add is idempotent so we
    # don't branch on platform.
    local host_allow_ip=""
    if [ -n "$resolved_hdi" ] && [ "$resolved_hdi" != "127.0.0.1" ]; then
        if ! docker exec -u root "$container" \
                /usr/local/bin/start-agent-browser-host-allow "$resolved_hdi" "$cdp_port"; then
            _warn "Failed to open container firewall slot for ${resolved_hdi}:${cdp_port}; rolling back Chrome, relay, and proxy."
            _warn "  (If you just pulled new devbox code, run 'devbox update' to rebuild the container with the new helper script.)"
            sudo -u devbox-agent kill "$chrome_pid" 2>/dev/null || true
            if [ -n "$relay_pid" ]; then
                sudo -u devbox-agent kill "$relay_pid" 2>/dev/null || true
            fi
            sudo -u devbox-agent kill "$proxy_pid" 2>/dev/null || true
            _cleanup_session_dirs "$profile_dir" "$download_dir" "${container}-"
            exit 1
        fi
        host_allow_ip="$resolved_hdi"
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
    # Force IPv4 (`TCP4:`) for the upstream side. Docker Desktop on WSL2
    # gives `host.docker.internal` a dual-stack response — both an IPv4
    # (192.168.65.254) and an IPv6 ULA (fdc4:...:254). Linux glibc per
    # RFC 6724 prefers IPv6, but Docker Desktop's forwarding to the host
    # loopback Chrome only covers IPv4. Without TCP4 the in-container
    # socat happily connects to the IPv6 address, never reaches host
    # Chrome, and exits — leaving the CDP smoke test below to fail.
    _log "Starting in-container bridge: ${container}:127.0.0.1:${BRIDGE_CONTAINER_PORT} -> host.docker.internal:${cdp_port}"
    if ! docker exec -d "$container" \
        socat \
            "TCP-LISTEN:${BRIDGE_CONTAINER_PORT},bind=127.0.0.1,fork,reuseaddr" \
            "TCP4:host.docker.internal:${cdp_port}"; then
        _warn "docker exec -d socat failed in ${container}; rolling back Chrome, relay, and proxy."
        if [ -n "$host_allow_ip" ]; then
            docker exec -u root "$container" \
                /usr/local/bin/stop-agent-browser-host-allow "$host_allow_ip" "$cdp_port" 2>/dev/null || true
        fi
        sudo -u devbox-agent kill "$chrome_pid" 2>/dev/null || true
        if [ -n "$relay_pid" ]; then
            sudo -u devbox-agent kill "$relay_pid" 2>/dev/null || true
        fi
        sudo -u devbox-agent kill "$proxy_pid" 2>/dev/null || true
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
        _warn "Bridge socat did not register inside ${container}; rolling back Chrome, relay, and proxy."
        if [ -n "$host_allow_ip" ]; then
            docker exec -u root "$container" \
                /usr/local/bin/stop-agent-browser-host-allow "$host_allow_ip" "$cdp_port" 2>/dev/null || true
        fi
        sudo -u devbox-agent kill "$chrome_pid" 2>/dev/null || true
        if [ -n "$relay_pid" ]; then
            sudo -u devbox-agent kill "$relay_pid" 2>/dev/null || true
        fi
        sudo -u devbox-agent kill "$proxy_pid" 2>/dev/null || true
        _cleanup_session_dirs "$profile_dir" "$download_dir" "${container}-"
        exit 1
    fi

    local created_at
    created_at="$(_iso_utc_now)"

    # Spawn the Chrome-death watchdog. Polls Chrome PID every
    # AGENT_WATCHDOG_INTERVAL_DEFAULT seconds; on Chrome exit (user
    # closed the window, crash, OOM) it invokes `broker stop` for
    # graceful proxy/relay/firewall teardown. Without it the user
    # closing the Chrome window leaves the session in a half-alive
    # state — proxy/relay still running, state file claiming the
    # session is up, and `devbox agent-browser status` reporting
    # Chrome `(dead)` with no automatic remediation. Best-effort:
    # if the watchdog cannot be spawned (script missing, fork failure)
    # we proceed without it — the user can still manually `stop`.
    #
    # Runs as the invoking developer (NOT under sudo -u devbox-agent)
    # so the watchdog's exec-of-broker-stop resolves SESSIONS_DIR /
    # state file paths against the developer's XDG_STATE_HOME — the
    # same paths cmd_start wrote into. Watchdog needs no elevated
    # privileges: ps -p / /proc reads work cross-user, and broker
    # stop will sudo where needed.
    #
    # PID capture is via pidfile written by the watchdog itself
    # (first line in agent-browser-watchdog.sh). pgrep against the
    # script name would race with the spawn wrapper's own cmdline
    # (`setsid`/`nohup`/`sh -c` all carry the watchdog script path as
    # an arg), occasionally returning the wrapper PID instead.
    local watchdog_pid=""
    if [ -x "$AGENT_WATCHDOG_SCRIPT" ]; then
        local watchdog_detach
        watchdog_detach="$(_detach_prefix)"
        local watchdog_log="$SESSIONS_DIR/${container}.watchdog.log"
        local watchdog_pidfile="$SESSIONS_DIR/${container}.watchdog.pid"
        # Stale pidfile cleanup from any prior session that crashed
        # before pidfile removal. The sweep above already covered
        # the prior session's processes; this just removes the file.
        rm -f -- "$watchdog_pidfile" 2>/dev/null || true
        $watchdog_detach "$AGENT_WATCHDOG_SCRIPT" \
            "$container" "$chrome_pid" "$AGENT_BROKER_SELF" "$watchdog_pidfile" \
            </dev/null >>"$watchdog_log" 2>&1 &
        disown 2>/dev/null || true

        # Poll the pidfile for ~1s. Watchdog writes it as its very
        # first action, so missing pidfile after 1s = spawn failure.
        local wd_retry
        for wd_retry in 1 2 3 4 5; do
            : "$wd_retry"
            if [ -s "$watchdog_pidfile" ]; then
                watchdog_pid="$(cat "$watchdog_pidfile" 2>/dev/null || true)"
                [ -n "$watchdog_pid" ] && break
            fi
            sleep 0.2
        done
        if [ -z "$watchdog_pid" ]; then
            _warn "Watchdog spawn failed (Chrome exit will not auto-trigger stop; manual 'devbox agent-browser stop' required if you close the window)."
        fi
    fi

    # Write state JSON. `active_network_window` stays null until slice 05
    # adds the network-window machinery. `relay_pid_host` is an addition
    # over the ADR's listed shape — host-side relay PID for native Linux
    # only; null elsewhere — needed so `stop` can clean it up.
    # `proxy_log_path` records the LIVE log location during the session
    # (under the ephemeral profile dir); `cmd_stop` archives it under
    # /var/log/devbox/agent-browser/ alongside the netlog and removes
    # the state file in the same step, so there is no post-archive
    # consumer of the field — keeping it as the live path matches the
    # `netlog_path` convention.
    local relay_pid_json="null"
    [ -n "$relay_pid" ] && relay_pid_json="$relay_pid"
    local host_allow_ip_json="null"
    [ -n "$host_allow_ip" ] && host_allow_ip_json="\"${host_allow_ip}\""
    local watchdog_pid_json="null"
    [ -n "$watchdog_pid" ] && watchdog_pid_json="$watchdog_pid"
    local state_file
    state_file="$(_state_file "$container")"
    cat > "$state_file" <<EOF
{
  "container": "${container}",
  "chrome_pid": ${chrome_pid},
  "bridge_pid_in_container": ${bridge_pid},
  "relay_pid_host": ${relay_pid_json},
  "proxy_pid": ${proxy_pid},
  "watchdog_pid": ${watchdog_pid_json},
  "cdp_port_host": ${cdp_port},
  "proxy_port_host": ${proxy_port},
  "profile_dir": "${profile_dir}",
  "download_dir": "${download_dir}",
  "netlog_path": "${netlog_path}",
  "proxy_log_path": "${proxy_log_live}",
  "host_allow_ip": ${host_allow_ip_json},
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
    _log "  Proxy PID (host):          ${proxy_pid}"
    [ -n "$watchdog_pid" ] && _log "  Watchdog PID (host):       ${watchdog_pid} (Chrome poll ${AGENT_WATCHDOG_INTERVAL_DEFAULT}s)"
    _log "  Bridge PID (in container): ${bridge_pid}"
    _log "  CDP (host):                127.0.0.1:${cdp_port}"
    _log "  Proxy (host):              127.0.0.1:${proxy_port} (default mode)"
    _log "  CDP (in container):        127.0.0.1:${BRIDGE_CONTAINER_PORT}"
    _log "  Profile dir:               ${profile_dir}"
    _log "  Proxy log (live):          ${proxy_log_live}"
    _log "  State:                     ${state_file}"
    _log "  CDP reachable from container: yes"
}

# --- Network window helpers --------------------------------------------------

# Re-snapshot the user's allowlist into the session-scoped staged copy
# so the SIGHUP triggered by `allow-for` also picks up any edits the
# user made to `agent-browser-allowed-domains.conf` since session
# start. Mode file is NOT touched — the allow-for caller owns its
# rewrite. Best-effort: a missing user-side allowlist leaves the
# staged file at its prior contents (or empty if no prior contents).
_restage_allowlist_only() {
    local profile_dir="$1"
    [ -n "$profile_dir" ] || return 1
    _is_managed_path "$profile_dir" "$AGENT_PROFILES_DIR" \
        || _die "Refusing to re-stage allowlist outside the managed profile parent."

    local staged_allowlist="${profile_dir}/allowed-domains.conf"
    if [ ! -r "$AGENT_ALLOWLIST_PATH" ]; then
        return 0
    fi
    # Truncate then refill, matching the staging shape used at session
    # start. `install -m 640 /dev/null` would zero the file but
    # piping the user's contents through `sudo -u devbox-agent tee`
    # both refills and respects the destination's owner.
    cat -- "$AGENT_ALLOWLIST_PATH" \
        | sudo -u devbox-agent tee "$staged_allowlist" >/dev/null \
        || _warn "Failed to re-stage allowlist to ${staged_allowlist}; proxy will keep prior allowlist."
    sudo -u devbox-agent chmod 640 "$staged_allowlist" 2>/dev/null || true
}

# Compose the JSON form of the mode-file. The proxy daemon's _read_mode
# parses either this JSON or the slice-04 legacy plain-text form; we
# write JSON exclusively from slice 05 onward so the proxy can enforce
# expiry directly without waiting on the host-side timer.
_mode_file_json() {
    local mode="$1" expires_at="${2:-}"
    if [ -z "$expires_at" ] || [ "$expires_at" = "null" ]; then
        printf '{"mode":"%s","expires_at":null}\n' "$mode"
    else
        printf '{"mode":"%s","expires_at":"%s"}\n' "$mode" "$expires_at"
    fi
}

# Write the staged mode file (the one the proxy actually reads, under
# the session profile dir, owned by devbox-agent) and the user-state
# copy (the user's record under ~/.local/state). The staged copy is
# canonical for proxy behaviour; the user-state copy is the historical
# `~/.local/state` record slice 04 introduced.
#
# `_is_managed_path` validates the staged path against the profile-dir
# anchor so a tampered session-state JSON cannot redirect the sudo tee
# at an arbitrary location.
_write_mode_file_pair() {
    local profile_dir="$1" mode="$2" expires_at="${3:-}"
    [ -n "$profile_dir" ] || return 1
    _is_managed_path "$profile_dir" "$AGENT_PROFILES_DIR" \
        || _die "Refusing to write mode file outside the managed profile parent: ${profile_dir}"

    local staged="${profile_dir}/active-mode"
    local payload
    payload="$(_mode_file_json "$mode" "$expires_at")"
    printf '%s' "$payload" \
        | sudo -u devbox-agent tee "$staged" >/dev/null \
        || _die "Failed to write staged mode file ${staged}."
    sudo -u devbox-agent chmod 640 "$staged" 2>/dev/null || true

    mkdir -p "$AGENT_PROXY_STATE_DIR"
    printf '%s' "$payload" > "$AGENT_PROXY_MODE_FILE"
    chmod 600 "$AGENT_PROXY_MODE_FILE" 2>/dev/null || true
}

# Update active_network_window inside the session-state JSON. Uses
# python3 (already a host dependency per mkcert / dns-install) so we
# avoid a jq dependency the broker explicitly tolerates the absence of.
# `state_file` is rewritten atomically via tmp + rename.
_state_set_network_window() {
    local state_file="$1" mode="$2" started_at="${3:-}" expires_at="${4:-}" timer_pid="${5:-}" harvest_log="${6:-}"
    [ -f "$state_file" ] || return 1
    python3 - "$state_file" "$mode" "$started_at" "$expires_at" "$timer_pid" "$harvest_log" <<'PY'
import json
import os
import sys

state_file, mode, started_at, expires_at, timer_pid, harvest_log = sys.argv[1:7]
with open(state_file, "r", encoding="utf-8") as fh:
    state = json.load(fh)

if mode == "null":
    state["active_network_window"] = None
else:
    window = {
        "started_at": started_at,
        "expires_at": expires_at,
    }
    if timer_pid and timer_pid != "null":
        try:
            window["timer_pid"] = int(timer_pid)
        except ValueError:
            window["timer_pid"] = None
    else:
        window["timer_pid"] = None
    if harvest_log and harvest_log != "null":
        window["harvest_log_path"] = harvest_log
    state["active_network_window"] = window

tmp = state_file + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(state, fh, indent=2)
    fh.write("\n")
os.replace(tmp, state_file)
PY
}

# Read the nested timer_pid from active_network_window. Returns empty
# when the window is closed or jq is missing AND the python fallback
# fails (defensive — python3 is a documented host dep). Errors are
# silenced because every call site treats empty as "no timer to kill".
_state_get_window_timer_pid() {
    local state_file="$1"
    [ -f "$state_file" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        jq -r '.active_network_window.timer_pid // empty' "$state_file" 2>/dev/null
        return 0
    fi
    python3 - "$state_file" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        data = json.load(fh)
    window = data.get("active_network_window")
    if window:
        pid = window.get("timer_pid")
        if pid is not None:
            print(pid)
except Exception:
    pass
PY
}

# --- Toast emission (slice 08) -----------------------------------------------

# Emit one agent-browser toast event (session-close or window-close) as a
# pending JSON for the host-side deliver script. Best-effort: every
# failure path returns 0 so notification dispatch never blocks the
# broker's stop or window-close flow. The pending dir is host-user-owned
# so no sudo is required; tmp + atomic rename keeps a half-written file
# from being picked up by a concurrent sweep.
#
# The pending JSON carries display fields only. The deliver script
# reconstructs the click-target path from the filename's
# `<container>-<ts_compact>` shape and the canonical archive / profile
# dirs (slice 08 AC #4) — the broker's `click_target_hint` is at most a
# diagnostic aid in the JSON; the deliver script never trusts it.
#
# Args:
#   $1 event           agent-browser-session-close | agent-browser-window-close
#   $2 container       devbox container name (already validated)
#   $3 ts_compact      session timestamp, [0-9]{8}T[0-9]{6}Z
#   $4 reason          for window-close: explicit-stop | timer-expiry | session-stop
#                      for session-close: explicit-stop | container-stop | unknown
#   $5 duration_secs   for session-close: integer seconds, or empty when unknown
#   $6 hint_path       diagnostic click-target hint (not trusted by deliver)
_emit_pending_event() {
    local event="$1" container="$2" ts_compact="$3" reason="${4:-}" duration_secs="${5:-}" hint_path="${6:-}"
    [ -n "$event" ] || return 0
    [ -n "$container" ] || return 0
    [ -n "$ts_compact" ] || return 0

    # Strict shape guard mirrors the deliver script's reconstruction
    # regex. Emitting a JSON the deliver script would later reject is a
    # silent dead-end; refuse early.
    case "$ts_compact" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;;
        *) _warn "agent-browser: refusing to emit event with malformed ts: ${ts_compact}"; return 0 ;;
    esac

    local kind=""
    case "$event" in
        agent-browser-session-close) kind="session" ;;
        agent-browser-window-close)  kind="window"  ;;
        *) _warn "agent-browser: refusing to emit unknown event: ${event}"; return 0 ;;
    esac

    mkdir -p "$AGENT_PENDING_DIR" 2>/dev/null || return 0
    chmod 700 "$AGENT_PENDING_DIR" 2>/dev/null || true

    # Per-emit suffix so a session that opens multiple network windows
    # (each producing its own window-close event) does not overwrite an
    # earlier pending that is still queued for retry. `date +%s%N`
    # is nanosecond-precision on GNU coreutils; on macOS BSD-date the
    # `%N` is literal — fall back to PID+RANDOM, which is still unique
    # enough at the per-broker-invocation granularity we need.
    local emit_ts
    emit_ts="$(date +%s%N 2>/dev/null || true)"
    case "$emit_ts" in
        *[!0-9]*|"") emit_ts="$(date +%s)$$${RANDOM}" ;;
    esac
    local pending="${AGENT_PENDING_DIR}/.pending-ab-${kind}-${container}-${ts_compact}-${emit_ts}.json"
    local pending_tmp
    pending_tmp="$(mktemp "${AGENT_PENDING_DIR}/.pending-ab-${kind}.XXXXXXXXXX" 2>/dev/null)" || return 0

    local duration_field='null'
    case "$duration_secs" in
        ''|*[!0-9]*) ;;
        *) duration_field="$duration_secs" ;;
    esac

    {
        printf '{\n'
        printf '  "event": "%s",\n' "$event"
        printf '  "container": "%s",\n' "$container"
        printf '  "session_ts": "%s",\n' "$ts_compact"
        printf '  "reason": "%s",\n' "$reason"
        printf '  "duration_seconds": %s,\n' "$duration_field"
        printf '  "click_target_hint": "%s",\n' "$hint_path"
        printf '  "emitted_at": "%s"\n'  "$(_iso_utc_now)"
        printf '}\n'
    } > "$pending_tmp" || { rm -f -- "$pending_tmp"; return 0; }
    chmod 600 "$pending_tmp" 2>/dev/null || true
    mv -- "$pending_tmp" "$pending" 2>/dev/null || { rm -f -- "$pending_tmp"; return 0; }

    if [ -x "$AGENT_DELIVER_BIN" ]; then
        local detach
        detach="$(_detach_prefix)"
        "$detach" "$AGENT_DELIVER_BIN" "$pending" </dev/null >/dev/null 2>&1 &
        disown 2>/dev/null || true
    fi
    return 0
}

# Compute seconds elapsed between two ISO-8601 UTC timestamps of the
# `%Y-%m-%dT%H:%M:%SZ` shape produced by `_iso_utc_now`. Echoes the
# integer count on stdout, empty string on parse failure. Used by
# `cmd_stop` to populate the session-close event's duration field.
_iso_duration_seconds() {
    local start="$1" end="$2"
    [ -n "$start" ] || return 0
    [ -n "$end" ] || return 0
    local start_epoch end_epoch
    start_epoch="$(date -u -d "$start" +%s 2>/dev/null || true)"
    if [ -z "$start_epoch" ]; then
        start_epoch="$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$start" +%s 2>/dev/null || true)"
    fi
    end_epoch="$(date -u -d "$end" +%s 2>/dev/null || true)"
    if [ -z "$end_epoch" ]; then
        end_epoch="$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$end" +%s 2>/dev/null || true)"
    fi
    [ -n "$start_epoch" ] && [ -n "$end_epoch" ] || return 0
    [ "$end_epoch" -ge "$start_epoch" ] || return 0
    printf '%s\n' $(( end_epoch - start_epoch ))
}

# Extract the session's compact-ISO ts suffix from a managed profile dir
# path, e.g. `/var/lib/devbox-agent/profiles/foo-20260519T123456Z` ->
# `20260519T123456Z`. Echoes empty when the path doesn't follow the
# expected `<container>-<ts>` tail or the ts portion doesn't match the
# strict shape. Used as the canonical event-id timestamp by the toast
# emitters so the deliver script can reconstruct trusted archive paths.
_session_ts_from_profile_dir() {
    local profile_dir="$1" container="$2"
    [ -n "$profile_dir" ] || return 0
    [ -n "$container" ] || return 0
    local basename suffix
    basename="${profile_dir##*/}"
    case "$basename" in
        "${container}-"*) suffix="${basename#"${container}-"}" ;;
        *) return 0 ;;
    esac
    case "$suffix" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) printf '%s\n' "$suffix" ;;
        *) return 0 ;;
    esac
}

# Spawn the host-side window-expiry timer. Sleeps until `expires_at`,
# then rewrites the staged mode file to `default` and SIGHUPs the
# proxy. Detached via setsid + nohup so the calling shell exiting does
# not take the timer with it.
#
# The timer runs as the invoking user (not devbox-agent) because it
# needs `sudo -u devbox-agent` to rewrite the staged mode file; sudo
# from a devbox-agent shell would be a privilege escalation the broker
# avoids.
#
# Echoes "<pid>" on success. PID identifies the bash subshell, which
# in turn holds the sleep child; killing the bash pid kills the sleep
# child as well (the trap below makes that explicit).
_start_window_timer() {
    local proxy_pid="$1" proxy_port="$2" profile_dir="$3" seconds="$4" state_file="$5" container="$6"
    [ -n "$proxy_pid" ] || return 1
    [ -n "$proxy_port" ] || return 1
    [ -n "$profile_dir" ] || return 1
    [ -n "$seconds" ] || return 1
    [ -n "$state_file" ] || return 1
    [ -n "$container" ] || return 1

    local proxy_marker="--listen 127.0.0.1:${proxy_port}"
    _is_managed_path "$profile_dir" "$AGENT_PROFILES_DIR" \
        || _die "Refusing to spawn timer with profile_dir outside managed parent."

    local detach mode_default_json
    detach="$(_detach_prefix)"
    mode_default_json="$(_mode_file_json default)"

    # The single-quoted body below is intentionally not expanded by the
    # outer shell: every $1..$7 / $sleep_pid is expanded inside the inner
    # `sh -c` once it starts running. Shellcheck would warn on the
    # trap's $sleep_pid otherwise.
    # shellcheck disable=SC2016
    "$detach" sh -c '
        # Trap so any signal received here (most importantly SIGTERM
        # from `cmd_stop` killing the timer pid) propagates to the
        # `sleep` child — otherwise the sleep keeps running detached.
        # Single quotes around the trap body defer $sleep_pid expansion
        # to the moment the trap fires; with double quotes the inner
        # shell would substitute the (still-empty) variable here at
        # install time, so the kill on a real expiry/stop would have
        # no target and would orphan the sleep child.
        sleep "$1" &
        sleep_pid=$!
        trap '"'"'kill -TERM "$sleep_pid" 2>/dev/null; exit 0'"'"' TERM INT HUP
        wait "$sleep_pid" 2>/dev/null
        rc=$?
        # rc=0 means sleep elapsed (window genuinely expired); any
        # other rc means we were signalled (cmd_allow_for reset-clock
        # or cmd_stop teardown), in which case do nothing — the
        # signaller already arranged the next state.
        if [ "$rc" -eq 0 ]; then
            # Rewrite the staged (proxy-canonical) mode file to default.
            # The staged file lives in a 0700 devbox-agent-owned dir, so
            # the write goes through sudo.
            printf "%s" "$2" \
                | sudo -u devbox-agent tee "$3/active-mode" >/dev/null 2>&1 || true
            # Rewrite the user-state copy in $HOME so the historical
            # record matches reality.
            if [ -n "$6" ]; then
                mkdir -p "$(dirname "$6")" 2>/dev/null || true
                printf "%s" "$2" > "$6" 2>/dev/null || true
                chmod 600 "$6" 2>/dev/null || true
            fi
            # Clear active_network_window in the session-state JSON so
            # status no longer reports an active window after expiry
            # and reset-clock paths do not try to kill a dead timer
            # via its stale recorded pid.
            if [ -n "$7" ] && [ -f "$7" ]; then
                python3 - "$7" <<"PYEOF" 2>/dev/null || true
import json, os, sys
state_path = sys.argv[1]
try:
    with open(state_path, "r", encoding="utf-8") as fh:
        state = json.load(fh)
except Exception:
    sys.exit(0)
state["active_network_window"] = None
tmp = state_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(state, fh, indent=2)
    fh.write("\n")
os.replace(tmp, state_path)
PYEOF
            fi
            # Only signal the proxy when its current cmdline still
            # bears the marker we recorded — the listen-port plus the
            # rest of the proxy bin name. Defends against PID reuse.
            if [ -r "/proc/$4/cmdline" ] \
                && tr "\0" " " < "/proc/$4/cmdline" 2>/dev/null \
                    | grep -qF -- "$5"; then
                sudo -u devbox-agent kill -HUP "$4" 2>/dev/null || true
            fi
            # Toast emit (slice 08, timer-expiry path). The full JSON
            # body is composed inline so we do not depend on sourcing
            # broker helpers from a detached subshell. Best-effort: any
            # failure falls through silently — the canonical record is
            # the proxy log on disk. The pending filename pattern must
            # match the deliver script reconstruction regex.
            if [ -n "${8:-}" ] && [ -n "${9:-}" ] && [ -n "${10:-}" ]; then
                pending_dir="$9"
                container_arg="$8"
                deliver_bin="${10}"
                profile_base=$(basename -- "$3")
                ts_compact=${profile_base#"${container_arg}-"}
                case "$ts_compact" in
                    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;;
                    *) ts_compact="" ;;
                esac
                if [ -n "$ts_compact" ]; then
                    mkdir -p "$pending_dir" 2>/dev/null || true
                    chmod 700 "$pending_dir" 2>/dev/null || true
                    emit_ts=$(date +%s%N 2>/dev/null || echo "")
                    case "$emit_ts" in
                        *[!0-9]*|"") emit_ts="$(date +%s)$$${RANDOM}" ;;
                    esac
                    pending_path="${pending_dir}/.pending-ab-window-${container_arg}-${ts_compact}-${emit_ts}.json"
                    pending_tmp=$(mktemp "${pending_dir}/.pending-ab-window.XXXXXXXXXX" 2>/dev/null || echo "")
                    if [ -n "$pending_tmp" ]; then
                        emitted_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
                        printf "%s\n" \
                            "{" \
                            "  \"event\": \"agent-browser-window-close\"," \
                            "  \"container\": \"${container_arg}\"," \
                            "  \"session_ts\": \"${ts_compact}\"," \
                            "  \"reason\": \"timer-expiry\"," \
                            "  \"duration_seconds\": null," \
                            "  \"click_target_hint\": \"${3}/proxy.log\"," \
                            "  \"emitted_at\": \"${emitted_at}\"" \
                            "}" \
                            > "$pending_tmp" \
                            && chmod 600 "$pending_tmp" 2>/dev/null \
                            && mv -- "$pending_tmp" "$pending_path" 2>/dev/null \
                            || rm -f -- "$pending_tmp"
                        if [ -x "$deliver_bin" ] && [ -e "$pending_path" ]; then
                            (
                                "$deliver_bin" "$pending_path" \
                                    </dev/null \
                                    >/dev/null 2>&1
                            ) &
                        fi
                    fi
                fi
            fi
        fi
    ' agent-browser-window-timer "$seconds" "$mode_default_json" "$profile_dir" "$proxy_pid" "$proxy_marker" "$AGENT_PROXY_MODE_FILE" "$state_file" "$container" "$AGENT_PENDING_DIR" "$AGENT_DELIVER_BIN" \
        </dev/null \
        >/dev/null 2>&1 &
    local timer_pid=$!
    disown "$timer_pid" 2>/dev/null || true

    # Sanity: the wrapper must still be alive an instant later, with
    # the expected cmdline marker — defends against the wrapper dying
    # before its trap installs, or pgrep returning a recycled pid.
    sleep 0.1
    if ! _pid_matches_marker "$timer_pid" "agent-browser-window-timer"; then
        return 1
    fi
    printf '%s\n' "$timer_pid"
}

# Kill a previously-spawned window timer. Best-effort; the wrapper's
# trap propagates the SIGTERM to its `sleep` child.
#
# Gates on the marker `agent-browser-window-timer` (the inner `sh -c`
# argv[0]) so a recorded timer_pid that has been recycled across a
# host crash/reboot does not cause us to signal an unrelated process.
# Mirrors the marker-match pattern used for Chrome / relay / proxy /
# bridge above.
_kill_window_timer() {
    local timer_pid="${1:-}"
    [ -n "$timer_pid" ] || return 0
    [ "$timer_pid" != "null" ] || return 0
    _pid_matches_marker "$timer_pid" "agent-browser-window-timer" || return 0
    kill -TERM "$timer_pid" 2>/dev/null || true
    local wait_ix
    for wait_ix in 1 2 3 4 5; do
        : "$wait_ix"
        _pid_matches_marker "$timer_pid" "agent-browser-window-timer" || return 0
        sleep 0.2
    done
    kill -KILL "$timer_pid" 2>/dev/null || true
}

# Resolve the proxy log archive path (the per-window subset of the
# JSONL stream is the suffix of this file from the moment the window
# opened — the proxy is a single shared stream, slice 06's summary
# generator splits per-window using `started_at`).
_session_proxy_log_live() {
    local state_file="$1"
    _state_get "$state_file" proxy_log_path 2>/dev/null || true
}

# --- subcommand: allow-for ---------------------------------------------------

cmd_allow_for() {
    # Parse args: either `<minutes> [<container>]` or `--stop [<container>]`.
    # Mirrors how the firewall allow-for dispatch in docker-run.sh shapes
    # its parsing, just at the broker level — the broker is the canonical
    # single entry point for this slice.
    local stop_mode=false
    local minutes=""
    local container=""
    local arg
    for arg in "$@"; do
        case "$arg" in
            --stop) stop_mode=true ;;
            ''|*[!0-9]*)
                [ -z "$container" ] || _die "Unexpected extra argument: ${arg}"
                container="$arg"
                ;;
            *)
                [ -z "$minutes" ] || _die "Unexpected extra minutes argument: ${arg}"
                minutes="$arg"
                ;;
        esac
    done

    if [ "$stop_mode" = true ]; then
        cmd_allow_for_stop "$container"
        return
    fi

    [ -n "$minutes" ] || _die "Missing minutes. Usage: agent-browser-broker.sh allow-for <minutes> <container>"

    # Validate the integer range; the broker is the trust anchor here
    # because it is invoked directly by tooling, not only through the
    # docker-run.sh dispatcher.
    case "$minutes" in
        ''|*[!0-9]*) _die "Minutes must be a positive integer (got '${minutes}')." ;;
    esac
    if [ "$minutes" -le 0 ] 2>/dev/null; then
        _die "Minutes must be a positive integer (got '${minutes}')."
    fi
    if [ "$minutes" -gt "$AGENT_ALLOW_FOR_MAX_MINUTES" ]; then
        _die "Minutes exceeds cap (${AGENT_ALLOW_FOR_MAX_MINUTES})."
    fi

    container="$(_require_container_arg "$container")"

    local state_file
    state_file="$(_state_file "$container")"
    [ -f "$state_file" ] \
        || _die "No Agent-browser session for '${container}'. Start one first: devbox agent-browser start ${container}"

    local proxy_pid proxy_port profile_dir
    proxy_pid="$(_state_get "$state_file" proxy_pid || true)"
    proxy_port="$(_state_get "$state_file" proxy_port_host || true)"
    profile_dir="$(_state_get "$state_file" profile_dir || true)"

    if [ -z "$proxy_pid" ] || [ "$proxy_pid" = "null" ]; then
        _die "Session for '${container}' has no proxy_pid — refusing to open a window against a half-started session."
    fi
    if [ -z "$proxy_port" ] || [ "$proxy_port" = "null" ]; then
        _die "Session for '${container}' has no proxy_port_host — state file may be from an older slice."
    fi
    if [ -z "$profile_dir" ] || [ "$profile_dir" = "null" ]; then
        _die "Session for '${container}' has no profile_dir — state file is malformed."
    fi
    if ! _is_managed_path "$profile_dir" "$AGENT_PROFILES_DIR" "${container}-"; then
        _die "Session profile_dir '${profile_dir}' is outside the managed parent — refusing to operate."
    fi

    local proxy_marker="--listen 127.0.0.1:${proxy_port}"
    _pid_matches_marker "$proxy_pid" "$proxy_marker" \
        || _die "Proxy PID ${proxy_pid} for '${container}' is no longer alive (or reused). Restart the session."

    # Reset-clock semantics — kill any existing timer before spawning the
    # new one. The mode file still lists `harvest` from the prior call;
    # we'll overwrite it in place.
    local existing_timer
    existing_timer="$(_state_get_window_timer_pid "$state_file" || true)"
    if [ -n "$existing_timer" ] && [ "$existing_timer" != "null" ]; then
        _kill_window_timer "$existing_timer"
    fi
    local existing_started
    if command -v jq >/dev/null 2>&1; then
        existing_started="$(jq -r '.active_network_window.started_at // empty' "$state_file" 2>/dev/null || true)"
    else
        existing_started="$(python3 - "$state_file" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        data = json.load(fh)
    window = data.get("active_network_window")
    if window:
        s = window.get("started_at")
        if s:
            print(s)
except Exception:
    pass
PY
)"
    fi

    local now_iso new_expires
    now_iso="$(_iso_utc_now)"
    new_expires="$(_iso_plus_minutes_utc "$minutes")" \
        || _die "Failed to compute expiry timestamp (date binary missing required flags?)."

    local started_at="$existing_started"
    [ -n "$started_at" ] || started_at="$now_iso"

    _restage_allowlist_only "$profile_dir"
    _write_mode_file_pair "$profile_dir" "harvest" "$new_expires"

    sudo -u devbox-agent kill -HUP "$proxy_pid" 2>/dev/null \
        || _warn "Failed to send SIGHUP to proxy PID ${proxy_pid}; the proxy will still notice expiry on the next request via the mode-file timestamp."

    local seconds
    seconds=$(( minutes * 60 ))
    local timer_pid=""
    timer_pid="$(_start_window_timer "$proxy_pid" "$proxy_port" "$profile_dir" "$seconds" "$state_file" "$container" || true)"
    if [ -z "$timer_pid" ]; then
        _warn "Window timer failed to start; the proxy will still self-revert at expiry but no SIGHUP will be issued."
        timer_pid=""
    fi

    local harvest_log
    harvest_log="$(_session_proxy_log_live "$state_file")"
    _state_set_network_window "$state_file" "harvest" "$started_at" "$new_expires" "$timer_pid" "$harvest_log"

    local action="opens"
    [ -n "$existing_started" ] && action="extended to"
    _log "Agent-browser network window ${action} ${minutes} min (until $(_local_hms "$new_expires") local) for ${container}."
}

cmd_allow_for_stop() {
    local container
    container="$(_require_container_arg "${1:-}")"

    local state_file
    state_file="$(_state_file "$container")"
    [ -f "$state_file" ] \
        || { _log "No Agent-browser session for ${container}."; return 0; }

    local proxy_pid proxy_port profile_dir
    proxy_pid="$(_state_get "$state_file" proxy_pid || true)"
    proxy_port="$(_state_get "$state_file" proxy_port_host || true)"
    profile_dir="$(_state_get "$state_file" profile_dir || true)"

    # Idempotent: if no window is open, this is a no-op success.
    local existing_timer existing_started
    existing_timer="$(_state_get_window_timer_pid "$state_file" || true)"
    if command -v jq >/dev/null 2>&1; then
        existing_started="$(jq -r '.active_network_window.started_at // empty' "$state_file" 2>/dev/null || true)"
    else
        existing_started="$(python3 - "$state_file" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        data = json.load(fh)
    window = data.get("active_network_window")
    if window:
        s = window.get("started_at")
        if s:
            print(s)
except Exception:
    pass
PY
)"
    fi
    if [ -z "$existing_started" ] && [ -z "$existing_timer" ]; then
        _log "No active network window for ${container} (idempotent no-op)."
        return 0
    fi

    if [ -n "$existing_timer" ] && [ "$existing_timer" != "null" ]; then
        _kill_window_timer "$existing_timer"
    fi

    if [ -n "$profile_dir" ] && [ "$profile_dir" != "null" ] \
        && _is_managed_path "$profile_dir" "$AGENT_PROFILES_DIR" "${container}-"; then
        _write_mode_file_pair "$profile_dir" "default"
    else
        _warn "Session profile_dir '${profile_dir}' is outside the managed parent; not rewriting staged mode file."
    fi

    local proxy_marker="--listen 127.0.0.1:${proxy_port}"
    if [ -n "$proxy_pid" ] && [ "$proxy_pid" != "null" ] \
        && [ -n "$proxy_port" ] && [ "$proxy_port" != "null" ] \
        && _pid_matches_marker "$proxy_pid" "$proxy_marker"; then
        sudo -u devbox-agent kill -HUP "$proxy_pid" 2>/dev/null \
            || _warn "SIGHUP to proxy PID ${proxy_pid} failed; the proxy will pick up the new mode file on its next request anyway."
    fi

    _state_set_network_window "$state_file" "null"
    _log "Agent-browser network window closed for ${container}."

    # Best-effort toast for the explicit-stop branch. Reconstruction in
    # the deliver script uses ${container}-${session_ts} so the live
    # proxy log is the natural pre-archive click target.
    local session_ts hint
    session_ts="$(_session_ts_from_profile_dir "$profile_dir" "$container" || true)"
    if [ -n "$session_ts" ]; then
        hint="${profile_dir}/proxy.log"
        _emit_pending_event "agent-browser-window-close" "$container" "$session_ts" \
            "explicit-stop" "" "$hint"
    fi
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

    local chrome_pid bridge_pid relay_pid proxy_pid watchdog_pid profile_dir download_dir
    local netlog_path proxy_log_path cdp_port proxy_port session_created_at
    local host_allow_ip
    chrome_pid="$(_state_get "$state_file" chrome_pid || true)"
    bridge_pid="$(_state_get "$state_file" bridge_pid_in_container || true)"
    relay_pid="$(_state_get "$state_file" relay_pid_host || true)"
    proxy_pid="$(_state_get "$state_file" proxy_pid || true)"
    watchdog_pid="$(_state_get "$state_file" watchdog_pid || true)"
    profile_dir="$(_state_get "$state_file" profile_dir || true)"
    download_dir="$(_state_get "$state_file" download_dir || true)"
    netlog_path="$(_state_get "$state_file" netlog_path || true)"
    proxy_log_path="$(_state_get "$state_file" proxy_log_path || true)"
    cdp_port="$(_state_get "$state_file" cdp_port_host || true)"
    proxy_port="$(_state_get "$state_file" proxy_port_host || true)"
    session_created_at="$(_state_get "$state_file" created_at || true)"
    host_allow_ip="$(_state_get "$state_file" host_allow_ip || true)"

    # Captured-on-success paths threaded into the post-archive summary
    # call below. Empty when the corresponding archive did not happen
    # (missing live file, managed-path check failed, or `sudo mv` errored
    # out). The summarizer accepts a missing path for either input.
    local archived_netlog_path="" archived_proxy_log_path=""

    local chrome_marker="--user-data-dir=$profile_dir"
    local relay_marker="TCP-LISTEN:${cdp_port}"
    local bridge_marker="socat TCP-LISTEN:${BRIDGE_CONTAINER_PORT}"
    local proxy_marker="--listen 127.0.0.1:${proxy_port}"
    local watchdog_marker="agent-browser-watchdog.sh $container"

    # Kill the Chrome-death watchdog first so it can't observe Chrome
    # dying (we're about to SIGTERM it below) and race with us by
    # re-invoking `broker stop` mid-teardown. Re-entry guard: when stop
    # is itself called from the watchdog (DEVBOX_AGENT_BROWSER_FROM_WATCHDOG=1),
    # skip the kill — the watchdog's PID is this process's parent and
    # signalling it would terminate the cleanup mid-flight.
    # Watchdog runs as the invoking user, so `kill` without sudo is the
    # right signal source.
    if [ "${DEVBOX_AGENT_BROWSER_FROM_WATCHDOG:-0}" != "1" ] \
        && [ -n "$watchdog_pid" ] && [ "$watchdog_pid" != "null" ] \
        && _pid_matches_marker "$watchdog_pid" "$watchdog_marker"; then
        _log "Stopping watchdog PID ${watchdog_pid}..."
        kill "$watchdog_pid" 2>/dev/null || true
    fi
    # Clean up watchdog log + pidfile alongside the state file removal.
    # Best-effort: a leftover log is not a correctness issue, just a
    # minor sessions-dir clutter that the next start's stale-sweep
    # would also miss (it only sweeps the state file itself).
    rm -f -- "$SESSIONS_DIR/${container}.watchdog.pid" \
             "$SESSIONS_DIR/${container}.watchdog.log" 2>/dev/null || true

    # Close any active network window first: kill the host-side timer so
    # it can't race with the proxy shutdown below (the proxy is about to
    # die regardless, but a timer firing during cmd_stop would try to
    # SIGHUP a dead PID and write to a soon-removed staged mode file).
    local window_timer_pid was_window_active=false window_started_at=""
    window_timer_pid="$(_state_get_window_timer_pid "$state_file" || true)"
    # Anchor window-active detection on `started_at` (always written
    # when cmd_allow_for opens a window) rather than `timer_pid` alone —
    # `_start_window_timer` may have failed and recorded the window with
    # a null pid, which still requires a session-stop toast at teardown.
    if command -v jq >/dev/null 2>&1; then
        window_started_at="$(jq -r '.active_network_window.started_at // empty' "$state_file" 2>/dev/null || true)"
    else
        window_started_at="$(python3 - "$state_file" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        data = json.load(fh)
    window = data.get("active_network_window")
    if window:
        s = window.get("started_at")
        if s:
            print(s)
except Exception:
    pass
PY
)"
    fi
    if [ -n "$window_started_at" ] && [ "$window_started_at" != "null" ]; then
        was_window_active=true
    fi
    if [ -n "$window_timer_pid" ] && [ "$window_timer_pid" != "null" ]; then
        _kill_window_timer "$window_timer_pid"
    fi

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

    if [ -n "$proxy_pid" ] && [ "$proxy_pid" != "null" ] \
        && [ -n "$proxy_port" ] && [ "$proxy_port" != "null" ] \
        && _pid_matches_marker "$proxy_pid" "$proxy_marker"; then
        _log "Stopping Agent-browser proxy PID ${proxy_pid}..."
        sudo -u devbox-agent kill "$proxy_pid" 2>/dev/null || true
    fi

    if _container_running "$container" \
        && [ -n "$bridge_pid" ] \
        && _pid_matches_marker_in_container "$container" "$bridge_pid" "$bridge_marker"; then
        _log "Stopping in-container bridge PID ${bridge_pid} in ${container}..."
        docker exec "$container" kill "$bridge_pid" 2>/dev/null || true
    else
        _log "Bridge PID ${bridge_pid:-?} already gone, reused, or container stopped."
    fi

    # Close the container-side firewall slot that cmd_start opened for the
    # CDP host IP+port. Idempotent — the stop helper removes all matching
    # ACCEPT rules. Skipped if the container is no longer running
    # (init-firewall flushes iptables on the next start anyway) or if the
    # CDP port is unknown (older state file from before port-scoping —
    # init-firewall has flushed the rule across any container restart, so
    # nothing to clean).
    if [ -n "$host_allow_ip" ] && [ "$host_allow_ip" != "null" ] \
        && [ -n "$cdp_port" ] && [ "$cdp_port" != "null" ] \
        && _container_running "$container"; then
        _log "Releasing container firewall slot for ${host_allow_ip}:${cdp_port}..."
        docker exec -u root "$container" \
            /usr/local/bin/stop-agent-browser-host-allow "$host_allow_ip" "$cdp_port" 2>/dev/null || true
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
                archived_netlog_path="$archive_path"
            else
                _warn "Failed to archive netlog from ${netlog_path} to ${archive_path}."
            fi
        else
            _warn "Refusing to archive netlog to suspicious path ${archive_path}."
        fi
    elif [ -n "$netlog_path" ] && [ "$netlog_path" != "null" ] && [ "$netlog_is_managed" != true ]; then
        _warn "State netlog_path '${netlog_path}' is outside the managed profile dir; skipping archive."
    fi

    # Archive proxy log on the same shape and pre-checks as the netlog
    # above. Same trust property: the proxy log path is sourced from a
    # developer-writable state JSON, so it MUST live under the managed
    # profile dir for the sudo mv to be safe.
    local proxy_log_is_managed=false
    if [ -n "$proxy_log_path" ] && [ "$proxy_log_path" != "null" ] \
        && [ -n "$profile_dir" ] && [ "$profile_dir" != "null" ] \
        && _is_managed_path "$profile_dir" "$AGENT_PROFILES_DIR" "${container}-" \
        && _is_managed_path "$proxy_log_path" "$profile_dir"; then
        proxy_log_is_managed=true
    fi
    if [ "$proxy_log_is_managed" = true ] && sudo test -f "$proxy_log_path"; then
        if [ ! -d "$AGENT_NETLOG_ARCHIVE_DIR" ]; then
            sudo mkdir -p "$AGENT_NETLOG_ARCHIVE_DIR"
            sudo chown devbox-agent: "$AGENT_NETLOG_ARCHIVE_DIR"
            sudo chmod 750 "$AGENT_NETLOG_ARCHIVE_DIR"
        fi
        local proxy_ts_suffix proxy_archive_path
        proxy_ts_suffix="${profile_dir##*/"${container}"-}"
        [ "$proxy_ts_suffix" = "$profile_dir" ] && proxy_ts_suffix=""
        [ -n "$proxy_ts_suffix" ] || proxy_ts_suffix="$(date -u +"%Y%m%dT%H%M%SZ")"
        proxy_archive_path="${AGENT_NETLOG_ARCHIVE_DIR}/${container}-${proxy_ts_suffix}.proxy.log"
        if _is_managed_path "$proxy_archive_path" "$AGENT_NETLOG_ARCHIVE_DIR" "${container}-"; then
            if sudo mv -- "$proxy_log_path" "$proxy_archive_path" 2>/dev/null; then
                sudo chown devbox-agent: "$proxy_archive_path" 2>/dev/null || true
                sudo chmod 640 "$proxy_archive_path" 2>/dev/null || true
                _log "Archived proxy log: ${proxy_archive_path}"
                archived_proxy_log_path="$proxy_archive_path"
            else
                _warn "Failed to archive proxy log from ${proxy_log_path} to ${proxy_archive_path}."
            fi
        else
            _warn "Refusing to archive proxy log to suspicious path ${proxy_archive_path}."
        fi
    elif [ -n "$proxy_log_path" ] && [ "$proxy_log_path" != "null" ] && [ "$proxy_log_is_managed" != true ]; then
        _warn "State proxy_log_path '${proxy_log_path}' is outside the managed profile dir; skipping archive."
    fi

    # Generate the session summary alongside the archives. Runs as
    # `devbox-agent` so the output file inherits the same owner as the
    # raw archives — readable to the user via group membership on the
    # archive dir (ADR 0010 § Tamper-proof property). Both inputs are
    # optional: a session that crashed before either log was written
    # still gets a summary noting that no logs were captured. Summary
    # failure is non-fatal; the broker's stop path keeps going so a
    # malformed netlog or a missing python3 cannot block teardown.
    if [ -f "$AGENT_SUMMARIZE_BIN" ]; then
        local summary_ts_suffix summary_path session_ended_at
        summary_ts_suffix=""
        if [ -n "$profile_dir" ] && [ "$profile_dir" != "null" ]; then
            summary_ts_suffix="${profile_dir##*/"${container}"-}"
            [ "$summary_ts_suffix" = "$profile_dir" ] && summary_ts_suffix=""
        fi
        [ -n "$summary_ts_suffix" ] || summary_ts_suffix="$(date -u +"%Y%m%dT%H%M%SZ")"
        summary_path="${AGENT_NETLOG_ARCHIVE_DIR}/${container}-${summary_ts_suffix}.summary.md"
        if _is_managed_path "$summary_path" "$AGENT_NETLOG_ARCHIVE_DIR" "${container}-"; then
            session_ended_at="$(_iso_utc_now)"
            local summary_cmd=(sudo -u devbox-agent python3 "$AGENT_SUMMARIZE_BIN"
                "--output" "$summary_path"
                "--session-start" "${session_created_at:-unknown}"
                "--session-end" "$session_ended_at"
                "--container" "$container")
            [ -n "$archived_netlog_path" ] \
                && summary_cmd+=("--netlog" "$archived_netlog_path")
            [ -n "$archived_proxy_log_path" ] \
                && summary_cmd+=("--proxy-log" "$archived_proxy_log_path")
            # Hand the staged allowlist (devbox-agent-readable copy used
            # by the proxy this session) to the summarizer so harvest-
            # mode requests that already match a rule are classified as
            # in-allowlist rather than out-of-allowlist. The user's
            # original ~/.config copy is 0600 under $HOME — devbox-agent
            # cannot traverse into it. Profile dir is still on disk at
            # this point; rm-rf below happens after this block.
            local staged_allowlist=""
            if [ -n "$profile_dir" ] && [ "$profile_dir" != "null" ] \
                && _is_managed_path "$profile_dir" "$AGENT_PROFILES_DIR" "${container}-"; then
                staged_allowlist="${profile_dir}/allowed-domains.conf"
                if sudo test -f "$staged_allowlist"; then
                    summary_cmd+=("--allowlist" "$staged_allowlist")
                fi
            fi
            if "${summary_cmd[@]}"; then
                sudo chmod 640 "$summary_path" 2>/dev/null || true
                _log "Wrote session summary: ${summary_path}"
            else
                _warn "Summary generator exited non-zero; session teardown continues."
            fi
        else
            _warn "Refusing to write summary to suspicious path ${summary_path}."
        fi
    else
        _warn "Summary generator missing at ${AGENT_SUMMARIZE_BIN}; skipping."
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

    # Toast emission (slice 08). Both events depend on a recoverable
    # session-ts; if the profile_dir tail did not parse we silently skip
    # — the canonical record is on disk under the archive dir.
    local session_ts
    session_ts="$(_session_ts_from_profile_dir "$profile_dir" "$container" || true)"
    if [ -n "$session_ts" ]; then
        if [ "$was_window_active" = true ]; then
            local window_hint=""
            [ -n "$archived_proxy_log_path" ] && window_hint="$archived_proxy_log_path"
            _emit_pending_event "agent-browser-window-close" "$container" "$session_ts" \
                "session-stop" "" "$window_hint"
        fi
        local duration_secs="" session_hint=""
        duration_secs="$(_iso_duration_seconds "$session_created_at" "$(_iso_utc_now)" || true)"
        # Prefer the summary archive path; reconstruction in the deliver
        # script targets the same `.summary.md` location anyway. Hint is
        # diagnostic only.
        session_hint="${AGENT_NETLOG_ARCHIVE_DIR}/${container}-${session_ts}.summary.md"
        _emit_pending_event "agent-browser-session-close" "$container" "$session_ts" \
            "explicit-stop" "$duration_secs" "$session_hint"
    fi
}

# --- subcommand: open --------------------------------------------------------

# Push one URL into the running session as a new tab via Chrome DevTools
# Protocol's HTTP endpoint `PUT /json/new?<url>`. The endpoint creates a
# top-level target in the default browser context — no WebSocket
# handshake, no extra Python dep. Chrome's anti-DNS-rebinding guard
# requires the Host header to be `localhost` (not `127.0.0.1`), so the
# call sets it explicitly. The 5s cap mirrors the cmd_start smoke-test
# pattern so a hung tab cannot stall the rest of the batch.
_open_url_via_cdp() {
    local cdp_port="$1" url="$2"
    [ -n "$cdp_port" ] || return 2
    [ -n "$url" ]      || return 2
    local encoded
    if command -v jq >/dev/null 2>&1; then
        encoded="$(jq -rn --arg u "$url" '$u|@uri')"
    else
        encoded="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$url")"
    fi
    curl -sS -X PUT \
        -H "Host: localhost" \
        --max-time 5 \
        --fail \
        --output /dev/null \
        "http://127.0.0.1:${cdp_port}/json/new?${encoded}"
}

cmd_open() {
    local container
    container="$(_require_container_arg "${1:-}")"
    shift
    if [ "$#" -eq 0 ]; then
        _warn "Usage: agent-browser-broker.sh open <container> <url> [<url>...]"
        exit 2
    fi

    local state_file
    state_file="$(_state_file "$container")"
    [ -f "$state_file" ] \
        || _die "No active session for ${container}. Run 'devbox agent-browser start ${container}' first."

    local cdp_port chrome_pid profile_dir
    cdp_port="$(_state_get "$state_file" cdp_port_host || true)"
    chrome_pid="$(_state_get "$state_file" chrome_pid || true)"
    profile_dir="$(_state_get "$state_file" profile_dir || true)"
    { [ -n "$cdp_port" ]    && [ "$cdp_port" != "null" ];    } \
        || _die "State file ${state_file} is missing cdp_port_host."
    { [ -n "$chrome_pid" ]  && [ "$chrome_pid" != "null" ];  } \
        || _die "State file ${state_file} is missing chrome_pid."
    { [ -n "$profile_dir" ] && [ "$profile_dir" != "null" ]; } \
        || _die "State file ${state_file} is missing profile_dir."

    # Liveness check matches cmd_status: the recorded PID must still
    # carry the --user-data-dir marker. Refuses to push URLs into a
    # stale session whose Chrome was killed externally.
    local chrome_marker="--user-data-dir=$profile_dir"
    if ! _pid_matches_marker "$chrome_pid" "$chrome_marker"; then
        _die "Chrome for ${container} is not alive (pid ${chrome_pid} no longer matches profile marker). Restart the session."
    fi

    local opened=0 failed=0 url
    for url in "$@"; do
        if _open_url_via_cdp "$cdp_port" "$url"; then
            opened=$((opened + 1))
            _log "Opened: ${url}"
        else
            failed=$((failed + 1))
            _warn "Failed to open: ${url}"
        fi
    done

    if [ "$opened" -eq 0 ]; then
        _warn "No URLs opened (${failed} failed)."
        exit 1
    fi
    if [ "$failed" -gt 0 ]; then
        _warn "${failed} URL(s) failed to open; ${opened} succeeded."
    fi
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

    local chrome_pid bridge_pid relay_pid proxy_pid watchdog_pid cdp_port proxy_port profile_dir created_at
    chrome_pid="$(_state_get "$state_file" chrome_pid || true)"
    bridge_pid="$(_state_get "$state_file" bridge_pid_in_container || true)"
    relay_pid="$(_state_get "$state_file" relay_pid_host || true)"
    proxy_pid="$(_state_get "$state_file" proxy_pid || true)"
    watchdog_pid="$(_state_get "$state_file" watchdog_pid || true)"
    cdp_port="$(_state_get "$state_file" cdp_port_host || true)"
    proxy_port="$(_state_get "$state_file" proxy_port_host || true)"
    profile_dir="$(_state_get "$state_file" profile_dir || true)"
    created_at="$(_state_get "$state_file" created_at || true)"

    local chrome_marker="--user-data-dir=$profile_dir"
    local relay_marker="TCP-LISTEN:${cdp_port}"
    local bridge_marker="socat TCP-LISTEN:${BRIDGE_CONTAINER_PORT}"
    local proxy_marker="--listen 127.0.0.1:${proxy_port}"
    local watchdog_marker="agent-browser-watchdog.sh $container"

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
    local proxy_line=""
    if [ -n "$proxy_pid" ] && [ "$proxy_pid" != "null" ]; then
        local proxy_status="dead"
        _pid_matches_marker "$proxy_pid" "$proxy_marker" && proxy_status="alive"
        proxy_line="  Proxy PID (host):          ${proxy_pid} (${proxy_status})"
    fi
    local watchdog_line=""
    if [ -n "$watchdog_pid" ] && [ "$watchdog_pid" != "null" ]; then
        local watchdog_status="dead"
        _pid_matches_marker "$watchdog_pid" "$watchdog_marker" && watchdog_status="alive"
        watchdog_line="  Watchdog PID (host):       ${watchdog_pid} (${watchdog_status})"
    fi

    cat <<EOF
Agent-browser session for ${container}:
  Created at:                ${created_at:-?}
  Chrome PID (host):         ${chrome_pid:-?} (${chrome_status})
EOF
    [ -n "$relay_line" ] && printf '%s\n' "$relay_line"
    [ -n "$proxy_line" ] && printf '%s\n' "$proxy_line"
    [ -n "$watchdog_line" ] && printf '%s\n' "$watchdog_line"
    cat <<EOF
  Bridge PID (in container): ${bridge_pid:-?} (${bridge_status})
  CDP (host):                127.0.0.1:${cdp_port:-?}
  Proxy (host):              127.0.0.1:${proxy_port:-?}
  CDP (in container):        127.0.0.1:${BRIDGE_CONTAINER_PORT}
  Profile dir:               ${profile_dir:-?}
  State file:                ${state_file}
EOF

    # Network window (slice 05). Only printed when the state file
    # records an active window — silent otherwise to keep `status` short
    # for the common no-window case. python3 is the canonical parser
    # for the nested object; the jq path is a faster shortcut when
    # available.
    local window_block=""
    if command -v jq >/dev/null 2>&1; then
        window_block="$(jq -r '
            if .active_network_window == null then
                empty
            else
                "  Network window:            harvest until \(.active_network_window.expires_at) (started \(.active_network_window.started_at))"
            end
        ' "$state_file" 2>/dev/null || true)"
    else
        window_block="$(python3 - "$state_file" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        data = json.load(fh)
    window = data.get("active_network_window")
    if window:
        print(f"  Network window:            harvest until {window.get('expires_at')} (started {window.get('started_at')})")
except Exception:
    pass
PY
)"
    fi
    if [ -n "$window_block" ]; then
        printf '%s\n' "$window_block"
    fi
}

# --- Dispatch ----------------------------------------------------------------

main() {
    local sub="${1:-}"
    [ -n "$sub" ] || { _usage >&2; exit 2; }
    shift
    case "$sub" in
        start)     cmd_start     "$@" ;;
        stop)      cmd_stop      "$@" ;;
        status)    cmd_status    "$@" ;;
        open)      cmd_open      "$@" ;;
        allow-for) cmd_allow_for "$@" ;;
        -h|--help|help) _usage ;;
        *) _usage >&2; exit 2 ;;
    esac
}

main "$@"
