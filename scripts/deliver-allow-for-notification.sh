#!/bin/bash
set -euo pipefail

# =============================================================================
# deliver-allow-for-notification — host-side notification dispatcher (ADR 0009)
# =============================================================================
# The in-container teardown daemon writes a small JSON `pending` file when a
# window closes (see scripts/teardown-allow-for-window.sh). This script reads
# those files and fires a notification on the host. Three modes:
#
#   <file.json>                One specific pending file. Used by --sweep
#                              under the hood; rarely called directly.
#   --sweep                    Scan /var/log/devbox/allow-for/ for every
#                              .pending-*.json and deliver each. Invoked at
#                              the start of every `devbox` command (fire-
#                              and-forget) so missed notifications surface
#                              on the user's next interaction.
#   --watch <container> <expires_iso>
#                              Background poller spawned by `devbox
#                              allow-for` start. Polls until either a
#                              pending arrives for this container, or
#                              <expires_iso> + grace passes (safety net for
#                              dead daemons).
#
# Cascade per platform:
#   WSL2 + powershell.exe   → COM toast with protocol activation → click
#                              opens the harvest log in the default editor.
#   Linux + notify-send     → passive notification; log path is in the
#                              body, no click action (depends on daemon).
#   macOS + osascript       → passive `display notification`; no click
#                              action without a third-party helper.
#   anything else           → silent. Harvest log is the canonical record.
#
# Delivery is best-effort. A failed dispatch leaves the pending file in
# place; the next --sweep retries.
# =============================================================================

# --- Constants ---------------------------------------------------------------
# Pending notification files (input to this script) live in a host-user-
# owned subdir so the atomic rename-claim below can succeed; the parent
# log dir stays root:root 0755 for the tamper-proof harvest-log
# guarantee (ADR 0009 §3-4). Harvest log paths come straight out of each
# pending JSON's `log_path` field, so this script never needs to know
# the log dir directly.
ALLOW_FOR_PENDING_DIR="/var/log/devbox/allow-for/pending"
WSL_APP_ID="Devbox.AllowFor"
# Files older than this are dropped on --sweep with a stderr warning. Keeps
# a stale pending from a long-past unclean shutdown from firing at every
# `devbox` invocation forever.
STALE_HOURS=24
# Watcher polling: snappy enough that the toast lands within seconds of the
# window closing, slow enough to be free on a laptop.
WATCH_POLL_SECONDS=10
# After expires_at, give the in-container daemon this long to actually
# write the pending file. Covers heartbeat latency, dnsmasq restart, log
# aggregation. Beyond that we conclude the daemon never delivered and exit
# the watcher so it doesn't loop forever.
WATCH_GRACE_SECONDS=120

# --- Diagnostics -------------------------------------------------------------
# Watcher and sweeper both run detached so stderr usually ends up in
# /dev/null. Keep the warnings anyway — direct invocation from a shell or
# from `bash -x` still surfaces them, and they're cheap.
_warn() { printf 'deliver-allow-for: WARN: %s\n' "$*" >&2; }

is_wsl2() { grep -qi microsoft /proc/version 2>/dev/null; }
is_macos() { [ "$(uname -s 2>/dev/null)" = "Darwin" ]; }

# Parse a timestamp produced by `allow_for::now_iso` /
# `allow_for::iso_plus_minutes` — i.e. `%Y-%m-%dT%H:%M:%S%z` like
# `2026-05-16T07:30:15+0200`. Prints the epoch on stdout; returns
# non-zero on parse failure.
#
# Two implementations: GNU date `-d` (Linux), then BSD date `-j -f`
# (macOS). The format string is fixed by the writer side, so we don't
# need to handle every ISO-8601 variant — just the one shape devbox
# actually emits.
iso_to_epoch() {
    local iso="$1" epoch
    if epoch=$(date -d "$iso" +%s 2>/dev/null); then
        printf '%s\n' "$epoch"
        return 0
    fi
    if epoch=$(date -j -f '%Y-%m-%dT%H:%M:%S%z' "$iso" +%s 2>/dev/null); then
        printf '%s\n' "$epoch"
        return 0
    fi
    return 1
}

# --- Pending JSON parsing ----------------------------------------------------
# Sets P_CONTAINER, P_LOG_PATH, P_REASON, P_DOMAIN_COUNT, P_TOP_DOMAINS as
# side effects so callers can read them without subshell-stripping arrays.
# Returns non-zero on a structurally broken file so the caller can leave
# the pending in place for human triage. Fields like started_at/ended_at
# live in the JSON for the harvest log's audit trail but aren't surfaced
# in the toast, so we skip parsing them.
#
# We control the writer (teardown-allow-for-window.sh do_teardown), so the
# JSON shape is fixed and flat — no nested objects, no arrays of objects.
# That's why a grep+sed fallback when jq is missing is acceptable; we never
# have to reason about JSON pathologies the writer can't produce.
parse_pending() {
    local file="$1"
    [ -f "$file" ] || return 1

    P_CONTAINER=""; P_LOG_PATH=""; P_REASON=""
    P_DOMAIN_COUNT=0; P_TOP_DOMAINS=""

    if command -v jq >/dev/null 2>&1; then
        local out
        # One jq invocation, tab-separated. `// ""` keeps missing fields
        # from breaking the read-into-vars below. `domain_count` is the
        # one numeric field; `// 0` keeps it parseable.
        out=$(jq -r '
            [ .container // "",
              .log_path  // "",
              .reason    // "",
              (.domain_count // 0),
              .top_domains // ""
            ] | @tsv
        ' "$file" 2>/dev/null) || return 1
        IFS=$'\t' read -r P_CONTAINER P_LOG_PATH P_REASON \
            P_DOMAIN_COUNT P_TOP_DOMAINS <<< "$out"
    else
        # Fallback parser for hosts without jq. Matches the exact shape
        # teardown-allow-for-window.sh writes: one `"key": value` or
        # `"key": "value"` per line. Strings are unquoted, numbers stay
        # literal. The regex tolerates leading whitespace and trailing
        # comma but nothing more exotic — fine because we own the writer.
        local raw key val
        while IFS= read -r raw; do
            key=$(printf '%s' "$raw" | sed -n 's/^[[:space:]]*"\([^"]*\)"[[:space:]]*:.*/\1/p')
            [ -z "$key" ] && continue
            val=$(printf '%s' "$raw" | sed -n 's/^[[:space:]]*"[^"]*"[[:space:]]*:[[:space:]]*\(.*\)[[:space:]]*$/\1/p')
            # Strip a single trailing comma (last field has none).
            val="${val%,}"
            # Strip a single pair of surrounding double-quotes for string
            # values. Numbers stay as-is.
            case "$val" in
                \"*\") val="${val#\"}"; val="${val%\"}" ;;
            esac
            case "$key" in
                container)    P_CONTAINER="$val" ;;
                log_path)     P_LOG_PATH="$val" ;;
                reason)       P_REASON="$val" ;;
                domain_count) P_DOMAIN_COUNT="$val" ;;
                top_domains)  P_TOP_DOMAINS="$val" ;;
            esac
        done < "$file"
    fi

    # Minimum viable record. log_path and container are mandatory; without
    # them the toast can't link to anything useful and the writer is
    # broken in a way the sweeper can't fix.
    [ -n "$P_CONTAINER" ] && [ -n "$P_LOG_PATH" ]
}

# --- Toast body composition --------------------------------------------------
# Sets T_TITLE and T_BODY based on the last parse_pending call. Kept pure
# (no fork/exec, no env-lookup) so it's trivial to test in isolation.
#
# Body shape is identical across platforms — the rendering layer
# (PowerShell vs notify-send vs osascript) differs only in how it places
# the strings on screen.
build_toast_body() {
    local title_verb
    case "$P_REASON" in
        stopped)     title_verb="closed manually" ;;
        interrupted) title_verb="interrupted by restart" ;;
        *)           title_verb="closed" ;;  # `expired` and unknown both fall here
    esac
    T_TITLE="devbox allow-for ${title_verb}: ${P_CONTAINER}"

    local count_line
    if [ "${P_DOMAIN_COUNT:-0}" = "0" ]; then
        count_line="No domains outside the allowlist were queried."
    elif [ "${P_DOMAIN_COUNT:-0}" = "1" ]; then
        count_line="1 domain outside the allowlist."
    else
        count_line="${P_DOMAIN_COUNT} domains outside the allowlist."
    fi

    local top_line=""
    if [ -n "$P_TOP_DOMAINS" ]; then
        # Writer joins top domains with `|`. Render as bullets, keep the
        # body compact for Action Center (~200 char target).
        top_line="Top: $(printf '%s' "$P_TOP_DOMAINS" | tr '|' '/' | sed 's:/: · :g')"
    fi

    if [ -n "$top_line" ]; then
        T_BODY="${count_line}"$'\n'"${top_line}"
    else
        T_BODY="${count_line}"
    fi
}

# --- Path conversion for Windows protocol activation ------------------------
# Turn /var/log/devbox/allow-for/<container>-<ts>.log into a file:// URI
# Windows accepts via the toast's protocol activation. Used as the toast
# launch attribute; click opens the log in the default .log handler
# (usually Notepad).
#
# `wslpath -w` returns a UNC like `\\wsl.localhost\Ubuntu\var\log\...`.
# RFC 8089 file: scheme uses forward slashes and pulls the UNC host into
# the authority component:
#
#   \\wsl.localhost\Ubuntu\var\log\foo.log
#                                              ↓
#   file://wsl.localhost/Ubuntu/var/log/foo.log
#
# Encoding pass keeps the URI-safe characters as-is and percent-encodes
# the rest. Notable triggers in real paths: `+` from timestamp offsets
# (`2026-05-16T07-30-15+0200`), spaces in distro names, `#`/`?` should
# they ever appear in container slugs.
to_file_uri() {
    local linux_path="$1" win_path forward uri
    win_path=$(wslpath -w "$linux_path" 2>/dev/null) || return 1
    [ -n "$win_path" ] || return 1
    # Backslashes → forward slashes. The leading `\\` of the UNC becomes
    # `//`, which combined with the `file:` emit below produces the
    # correct `file://<host>/...` authority form.
    forward="${win_path//\\//}"
    uri=$(printf '%s' "$forward" | awk '
        BEGIN {
            for (i = 0; i < 256; i++) hex[sprintf("%c", i)] = sprintf("%%%02X", i)
        }
        {
            out = ""
            n = length($0)
            for (i = 1; i <= n; i++) {
                ch = substr($0, i, 1)
                if (ch ~ /[A-Za-z0-9._~\/:-]/) out = out ch
                else                            out = out hex[ch]
            }
            print out
        }
    ')
    printf 'file:%s\n' "$uri"
}

# --- Backend availability predicates ----------------------------------------
# Cleanly separate "is this backend applicable on this host" from "did
# delivery succeed". deliver_one uses the predicates to pick which
# backend's deliver_* function to call; transient delivery failures
# (e.g. powershell.exe rc != 0, DBus down) trigger retry-on-next-sweep,
# while a host with no applicable backend at all gets one warning and
# the pending is dropped to avoid looping forever against a dead cascade.
backend_available_windows() {
    is_wsl2 \
        && command -v powershell.exe >/dev/null 2>&1 \
        && command -v wslpath        >/dev/null 2>&1
}
backend_available_macos() {
    is_macos && command -v osascript >/dev/null 2>&1
}
backend_available_linux() {
    command -v notify-send >/dev/null 2>&1 \
        && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]
}

# --- Delivery: Windows COM toast --------------------------------------------
# Inline COM toast under the HKCU AppId provisioned in
# ensure-allow-for-host-state.sh. Click activation goes through protocol
# activation — Windows resolves the `launch` URI through its standard
# protocol handlers, which is why no UWP activator COM server registration
# is needed (`activationType="protocol"`).
#
# The inner PowerShell script reads its inputs from env vars (set on the
# powershell.exe invocation) instead of string-interpolating them, so we
# never have to worry about escaping quotes, ampersands, or newlines in
# the body. Toast XML escaping happens inside PowerShell via
# [System.Security.SecurityElement]::Escape.
#
# Returns 0 on Show() success; non-zero on transient failure (PowerShell
# rc != 0). Caller guarantees the platform is WSL2 and powershell.exe +
# wslpath are present (see backend_available_windows).
deliver_windows() {
    local launch_uri
    launch_uri=$(to_file_uri "$P_LOG_PATH") || launch_uri=""

    local inner
    inner=$(cat <<'PS_INNER'
$ErrorActionPreference = 'Stop'
try {
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType=WindowsRuntime] | Out-Null

    $title  = [System.Security.SecurityElement]::Escape($env:DEVBOX_TOAST_TITLE)
    $body   = [System.Security.SecurityElement]::Escape($env:DEVBOX_TOAST_BODY)
    $launch = [System.Security.SecurityElement]::Escape($env:DEVBOX_TOAST_LAUNCH)
    $appId  = $env:DEVBOX_TOAST_APPID

    # Body may legitimately contain a newline (count line + top line).
    # Two <text> elements render as separate lines inside the toast body.
    $bodyParts = $body -split "`n", 2
    $bodyXml = ""
    foreach ($p in $bodyParts) {
        if ($p) { $bodyXml += "<text>$p</text>" }
    }

    if ($launch) {
        $toastXml = "<toast activationType='protocol' launch='$launch'><visual><binding template='ToastGeneric'><text>$title</text>$bodyXml</binding></visual></toast>"
    } else {
        $toastXml = "<toast><visual><binding template='ToastGeneric'><text>$title</text>$bodyXml</binding></visual></toast>"
    }

    $xmlDoc = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType=WindowsRuntime]::new()
    $xmlDoc.LoadXml($toastXml)

    $toast    = [Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType=WindowsRuntime]::new($xmlDoc)
    $notifier = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]::CreateToastNotifier($appId)
    $notifier.Show($toast)
    exit 0
} catch {
    exit 1
}
PS_INNER
)

    local encoded
    encoded=$(printf '%s' "$inner" | iconv -t UTF-16LE 2>/dev/null | base64 -w0 2>/dev/null) || return 1

    DEVBOX_TOAST_APPID="$WSL_APP_ID" \
    DEVBOX_TOAST_TITLE="$T_TITLE" \
    DEVBOX_TOAST_BODY="$T_BODY" \
    DEVBOX_TOAST_LAUNCH="$launch_uri" \
        powershell.exe -NoProfile -EncodedCommand "$encoded" >/dev/null 2>&1
}

# --- Delivery: Linux notify-send --------------------------------------------
# Passive notification with the harvest log path interpolated into the body.
# notify-send `-A` actions exist but require a blocking listener and depend
# on the daemon's action support; for fire-and-forget we just show the path
# and let the user open it themselves.
#
# Returns 0 on notify-send success, non-zero on transient failure (DBus
# unreachable, malformed display, etc.). Caller guarantees notify-send is
# in PATH and a display env var is set.
deliver_linux() {
    # notify-send treats -u low as transient — fine here, the canonical
    # record is the log file. Keep the path on its own line so even
    # daemons that truncate aggressively show enough.
    notify-send -u low -a "devbox" \
        "$T_TITLE" \
        "${T_BODY}"$'\n'"Log: ${P_LOG_PATH}" 2>/dev/null
}

# --- Delivery: macOS osascript ----------------------------------------------
# `display notification` from osascript has no click activation. We render
# the body and include the path so the user can copy-paste it. Caller
# guarantees the platform is Darwin and osascript is available.
deliver_macos() {
    # AppleScript strings escape `"` as `\"`. Title and body come from
    # parse_pending (controlled input), but escape defensively anyway.
    local title body path
    title=${T_TITLE//\"/\\\"}
    body=${T_BODY//\"/\\\"}
    body="${body//$'\n'/ — }"
    path=${P_LOG_PATH//\"/\\\"}
    osascript -e "display notification \"${body} — Log: ${path}\" with title \"${title}\"" >/dev/null 2>&1
}

# --- Cascade -----------------------------------------------------------------
# Deliver one pending file. Three possible outcomes:
#
#   delivered  Backend was applicable AND succeeded. Drop the claim.
#   failed     Backend was applicable but failed transiently (PowerShell
#              rc != 0, DBus down, osascript error). Restore claim →
#              pending so the next sweep retries.
#   silent     No applicable backend on this host (headless server,
#              non-WSL2 Windows distro, etc.). Drop the claim — retrying
#              against the same dead cascade would spam forever; the
#              harvest log is canonical anyway.
#
# Concurrent deliveries (reset-clock spawns a second watcher; sweep races
# a watcher) are serialised via atomic rename-claim: whichever process
# wins the `mv pending → pending.lock` race owns the delivery; the
# loser's `mv` returns non-zero and it bails out cleanly.
deliver_one() {
    local pending="$1"
    local claim="${pending}.lock"

    # rename(2) is atomic on Linux/macOS: exactly one of N concurrent
    # `mv pending claim` calls succeeds; the rest fail with ENOENT. The
    # `.lock` suffix lands outside both sweep (`.pending-*.json`) and
    # watch (`.pending-<container>-*.json`) globs, so a half-delivered
    # file isn't re-picked-up by a sibling process.
    if ! mv "$pending" "$claim" 2>/dev/null; then
        return 0
    fi

    if ! parse_pending "$claim"; then
        _warn "unparseable pending file: $pending — leaving in place"
        # Restore so a human can inspect and the next sweep doesn't
        # vanish the file. rm -f fallback if restore itself fails
        # (e.g. perms changed mid-flight): a broken pending we can't
        # parse is no use to retry anyway.
        mv "$claim" "$pending" 2>/dev/null || rm -f "$claim"
        return 1
    fi

    # --- Filesystem-trust validation (security boundary) ---
    # The pending hand-off dir is host-user-owned, so the in-container
    # node user (UID 1000 on both sides of the bind mount) can forge,
    # replace, or delete `.pending-*.json` files. Treat every JSON
    # field as untrusted input. Instead, lean on filesystem invariants
    # the attacker CANNOT subvert:
    #
    #   - Legit pending filename matches the writer pattern produced
    #     by start-allow-for-window + teardown-allow-for-window:
    #     `.pending-<container>-<ts_safe>.json`. Container names go
    #     through devbox::sanitize → [a-zA-Z0-9-]+; ts_safe is a
    #     strict YYYY-MM-DDTHH-MM-SS±HHMM shape (colons → dashes).
    #   - The corresponding harvest log lives at
    #     /var/log/devbox/allow-for/<container>-<ts_safe>.log. That
    #     directory is root:root 0755 with files 0644 root-owned —
    #     the in-container node user has NO write access there, so a
    #     forged pending pointing at a non-existent harvest log fails
    #     this existence check and gets dropped.
    #
    # Override JSON-supplied log_path and container with the trusted
    # derivatives; the attacker-controlled fields that remain
    # (reason, domain_count, top_domains) only feed the toast body
    # text, so the worst case is a misleading message — no path or
    # protocol-handler control. Defensively bound those too.
    # Derive basename from the ORIGINAL pending path, not $claim — after
    # the atomic rename, $claim has a `.json.lock` suffix that basename
    # wouldn't strip in one pass.
    local pending_base
    pending_base=$(basename "$pending" .json)
    pending_base="${pending_base#.pending-}"
    # Note: `[-+]` (dash first) — `[+-]` in some bash builds is parsed as
    # the range U+002B..U+002D (`+,-`), which happens to include `+` but
    # tickles a locale-dependent BASH_REMATCH bug where captures come
    # back empty even on a successful match. Dash-first is unambiguous.
    if ! [[ "$pending_base" =~ ^([a-zA-Z0-9-]+)-([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}[-+][0-9]{4})$ ]]; then
        _warn "rejecting pending: filename does not match writer pattern: $pending"
        rm -f "$claim"
        return 1
    fi
    local trusted_container="${BASH_REMATCH[1]}"
    local trusted_log_path="/var/log/devbox/allow-for/${pending_base}.log"
    if [ ! -f "$trusted_log_path" ]; then
        _warn "rejecting pending: corresponding harvest log missing: $trusted_log_path"
        rm -f "$claim"
        return 1
    fi
    P_CONTAINER="$trusted_container"
    P_LOG_PATH="$trusted_log_path"
    case "$P_REASON" in
        expired|stopped|interrupted) ;;
        *) P_REASON="expired" ;;
    esac
    case "$P_DOMAIN_COUNT" in
        *[!0-9]*|"") P_DOMAIN_COUNT=0 ;;
    esac
    # Bound the attacker-controlled top-domains string before it
    # reaches the renderers. Each backend does its own XML / shell
    # escaping, but a kilobyte-long body can wedge Action Center
    # rendering on Windows; cap it here so all paths benefit.
    P_TOP_DOMAINS="${P_TOP_DOMAINS:0:200}"

    build_toast_body

    # Pick a backend by applicability, then run delivery. Outcome
    # depends on both — only "applicable but failed" preserves the
    # pending file for retry.
    local outcome="silent"
    if backend_available_windows; then
        if deliver_windows; then outcome="delivered"; else outcome="failed"; fi
    elif backend_available_macos; then
        if deliver_macos;   then outcome="delivered"; else outcome="failed"; fi
    elif backend_available_linux; then
        if deliver_linux;   then outcome="delivered"; else outcome="failed"; fi
    fi

    case "$outcome" in
        delivered)
            rm -f "$claim"
            ;;
        silent)
            # One quiet log line per pending — the harvest log on disk
            # is the canonical record, the user just won't see a toast.
            _warn "no notification backend available — relying on harvest log: $P_LOG_PATH"
            rm -f "$claim"
            ;;
        failed)
            # Restore for the next sweep to retry. If restore itself
            # fails (e.g. someone deleted the claim out from under us),
            # rm -f the claim — we'd rather lose one notification than
            # leave a stray .lock blocking the slot forever.
            _warn "notification backend failed — preserving pending for retry: $pending"
            mv "$claim" "$pending" 2>/dev/null || rm -f "$claim"
            return 1
            ;;
    esac
}

# --- Stale pruning -----------------------------------------------------------
# Drop pending files older than STALE_HOURS so a long-past unclean shutdown
# doesn't fire toasts on every `devbox` invocation. Stderr-only warning.
prune_stale() {
    [ -d "$ALLOW_FOR_PENDING_DIR" ] || return 0
    local stale
    # `-mmin +N` is portable across coreutils-find and BSD-find. Convert
    # hours to minutes once.
    # Pattern intentionally matches both `.pending-*.json` (legit hand-off
    # files) and `.pending-*.json.lock` (claim leftovers from a crashed
    # delivery) — both should age out by the same clock. Anything else
    # under this dotfile prefix is unexpected and worth sweeping too.
    stale=$(find "$ALLOW_FOR_PENDING_DIR" -maxdepth 1 -name '.pending-*' \
        -mmin "+$((STALE_HOURS * 60))" 2>/dev/null) || return 0
    [ -z "$stale" ] && return 0
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        _warn "dropping stale pending (>${STALE_HOURS}h): $f"
        rm -f "$f"
    done <<< "$stale"
}

# --- Sweep -------------------------------------------------------------------
# Iterate every .pending-*.json. Each delivery is independent; one failure
# doesn't abort the rest.
sweep() {
    [ -d "$ALLOW_FOR_PENDING_DIR" ] || return 0
    prune_stale
    local pending
    # `nullglob`-style: explicitly check the glob expanded to anything,
    # otherwise the literal `.pending-*.json` would be passed to the loop.
    local matched=false
    for pending in "$ALLOW_FOR_PENDING_DIR"/.pending-*.json; do
        [ -e "$pending" ] || continue
        matched=true
        deliver_one "$pending" || true
    done
    [ "$matched" = false ] && return 0
    return 0
}

# --- Watch -------------------------------------------------------------------
# Spawned by `devbox allow-for` start branch. Wait for *this container's*
# pending file. Exit as soon as one arrives (and is delivered), or after
# expires_at + grace if the daemon never wrote one.
#
# Multiple watchers may coexist (reset-clock spawns a new one). Whichever
# wins delivers the pending and exits; the others reach grace and exit
# quietly. Safe because deliver_one's rm -f is atomic at the syscall level.
watch_window() {
    local container="$1" expires_iso="$2"
    [ -n "$container" ] || { _warn "watch: missing container"; return 2; }
    [ -n "$expires_iso" ] || { _warn "watch: missing expires_at"; return 2; }

    local expires_epoch deadline_epoch
    expires_epoch=$(iso_to_epoch "$expires_iso") || {
        _warn "watch: unparseable expires_at: $expires_iso"
        return 2
    }
    deadline_epoch=$((expires_epoch + WATCH_GRACE_SECONDS))

    local pending_glob="${ALLOW_FOR_PENDING_DIR}/.pending-${container}-*.json"
    local now pending
    while :; do
        # Match any pending file for this container. Reset-clock changes
        # the expires_at on the sentinel but the container name stays
        # constant, so the glob is stable across the window's lifetime.
        for pending in $pending_glob; do
            [ -e "$pending" ] || continue
            deliver_one "$pending" || true
            return 0
        done
        now=$(date +%s)
        [ "$now" -ge "$deadline_epoch" ] && return 0
        sleep "$WATCH_POLL_SECONDS"
    done
}

# --- Dispatch ----------------------------------------------------------------
case "${1:-}" in
    --sweep)
        sweep
        ;;
    --watch)
        shift
        watch_window "${1:-}" "${2:-}"
        ;;
    --help|-h|"")
        sed -n '4,32p' "$0"
        ;;
    -*)
        _warn "unknown flag: $1"
        exit 2
        ;;
    *)
        deliver_one "$1"
        ;;
esac
