# shellcheck shell=bash
# =============================================================================
# Devbox allow-for window helpers (ADR 0009)
# =============================================================================
# Sourced by the three in-container scripts that drive the allow-for window:
#   - start-allow-for-window   (root) opens the window
#   - teardown-allow-for-window (root) closes it and writes the harvest log
#   - show-allow-for-status     (node) prints status while a window is active
#
# Functions never assume which user is calling — read-only operations stay
# permission-clean for the node user; write paths are root-only and protected
# by filesystem perms set at install time (see ensure-allow-for-host-state.sh).
# =============================================================================

# Constants consumed by sourcing scripts; shellcheck can't see that.
# shellcheck disable=SC2034

# --- Paths -------------------------------------------------------------------
ALLOW_FOR_SENTINEL="/etc/devbox-shared/.allow-for.state"
ALLOW_FOR_DNSMASQ_CONF="/etc/dnsmasq.d/devbox-allow-for.conf"
ALLOW_FOR_LOG_DIR="/var/log/devbox/allow-for"
# Pending notification files (Phase 3 hand-off to the host deliver script)
# live in a separate subdirectory that is host-user-owned, so the host-side
# deliver script can atomically rename-claim them. The parent ALLOW_FOR_LOG_DIR
# stays root:root 0755 for the tamper-proof harvest-log guarantee (ADR 0009
# §3-4); only this subdir is host-user-writable. See
# scripts/ensure-allow-for-host-state.sh for the provisioning step.
ALLOW_FOR_PENDING_DIR="/var/log/devbox/allow-for/pending"
# Root-only scratch space for the teardown daemon's atomic publish of
# pending JSON files. Sibling of pending/ inside the same bind mount —
# critical because rename(2) requires same-filesystem operands and the
# pending dir is on a separate mount from the container rootfs. The .tmp/
# parent (allow-for/) is root:root 0755, so the in-container node user
# cannot rmdir or replace .tmp/ even though they own pending/; the
# subdir itself is 0700 root:root, so the attacker can't enumerate or
# pre-create files inside. Together those properties close the TOCTOU
# race where an attacker could swap a tempfile for a symlink between
# mktemp and the daemon's `cat >`.
ALLOW_FOR_TMP_DIR="/var/log/devbox/allow-for/.tmp"
# Daemon's stdout/stderr go inside the bind-mounted log dir as a dotfile
# so they're visible from the host alongside harvest logs (useful when
# diagnosing window-open failures) without colliding with `<container>-
# <ts>.log` filenames. A `mkdir -p` in start-allow-for-window keeps this
# path working even if the container was started before Phase 1 host
# state existed (in that case the dir lives on container rootfs, not on
# the host — diagnostic-only, gone on restart).
ALLOW_FOR_DAEMON_LOG="/var/log/devbox/allow-for/.daemon.log"
ALLOW_FOR_IPSET="harvest-pool"
ALLOW_FOR_DNSMASQ_QUERIES="/var/log/dnsmasq-queries.log"

# --- Sentinel parsing --------------------------------------------------------
# The sentinel is a tiny key=value file. Keys: started_at, expires_at,
# container, daemon_pid, log_start_byte. Values are unquoted scalars; the
# format is intentionally trivial so a `grep | cut` reader works for the
# node user without any parser library.
#
# Usage: allow_for::get_field <field>
# Prints the value on stdout; returns 1 if the field or sentinel is missing.
allow_for::get_field() {
    local field="$1"
    [ -f "$ALLOW_FOR_SENTINEL" ] || return 1
    local line
    line=$(grep -E "^${field}=" "$ALLOW_FOR_SENTINEL" 2>/dev/null | head -1) || return 1
    [ -n "$line" ] || return 1
    printf '%s\n' "${line#*=}"
}

# True if a sentinel exists. Doesn't say whether the window is still live —
# use `allow_for::is_expired` for that.
allow_for::sentinel_exists() {
    [ -f "$ALLOW_FOR_SENTINEL" ]
}

# True if the sentinel's expires_at is in the past (or unparseable, which
# we treat as expired to fail safe — better to teardown an unknown state
# than leak the window).
allow_for::is_expired() {
    local expires_at now_epoch exp_epoch
    expires_at=$(allow_for::get_field expires_at) || return 0
    now_epoch=$(date +%s)
    exp_epoch=$(date -d "$expires_at" +%s 2>/dev/null) || return 0
    [ "$now_epoch" -ge "$exp_epoch" ]
}

# --- Harvest aggregation -----------------------------------------------------
# Read dnsmasq query log from a byte offset and emit the unique set of
# A/AAAA-queried domains that are NOT covered by the allowlist (exact or
# subdomain match). Mirrors the `MODE=blocked` semantics in docker-run.sh.
#
# Usage: allow_for::harvest_domains <start_byte> [allowlist_file]
#   - start_byte:     0 reads the whole file; non-zero starts after that offset.
#   - allowlist_file: defaults to /etc/devbox-shared/allowed-domains.conf.
#
# Prints one domain per line, sorted, deduplicated. Empty output is normal
# (no non-allowlist queries yet).
allow_for::harvest_domains() {
    local start_byte="${1:-0}"
    local allowlist_file="${2:-/etc/devbox-shared/allowed-domains.conf}"

    [ -f "$ALLOW_FOR_DNSMASQ_QUERIES" ] || return 0

    # Slice the log to just-this-window. `tail -c +N` is 1-indexed; the
    # sentinel stores a 0-based byte count (post-restart wc -c), so +1.
    local skip=$((start_byte + 1))
    local queried
    queried=$(tail -c "+${skip}" "$ALLOW_FOR_DNSMASQ_QUERIES" 2>/dev/null \
        | grep -E "query\[(A|AAAA)\]" \
        | grep -oP "query\[(A|AAAA)\] \K[^ ]+" \
        | sort -u || true)

    [ -n "$queried" ] || return 0

    # Build the allowlist set with `*.` stripped — `*.foo.com` and `foo.com`
    # are equivalent under our convention (lib/allowlist.sh).
    local allowed
    if [ -f "$allowlist_file" ]; then
        allowed=$(sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
                      -e 's/^\*\.//' "$allowlist_file" \
            | grep -v '^$' \
            | sort -u || true)
    else
        allowed=""
    fi

    # Emit queried domains that are neither exact matches nor subdomains
    # of any allowlist entry. Same comparison as docker-run.sh:2316-2324.
    local domain allow is_allowed
    while IFS= read -r domain; do
        [ -z "$domain" ] && continue
        is_allowed=false
        while IFS= read -r allow; do
            [ -z "$allow" ] && continue
            if [ "$domain" = "$allow" ] || [[ "$domain" == *.${allow} ]]; then
                is_allowed=true
                break
            fi
        done <<< "$allowed"
        [ "$is_allowed" = false ] && printf '%s\n' "$domain"
    done <<< "$queried"
}

# --- Time helpers ------------------------------------------------------------
# ISO 8601 in the local timezone — used for machine-parseable fields
# (sentinel state, pending JSON). Kept ISO because the host-side
# deliver script's iso_to_epoch parses both GNU `date -d` and BSD
# `date -j -f '%Y-%m-%dT%H:%M:%S%z'`, and the latter requires the
# fixed `T`-separated shape.
allow_for::now_iso() { date '+%Y-%m-%dT%H:%M:%S%z'; }

# "+15 min" → ISO 8601 timestamp, local TZ.
allow_for::iso_plus_minutes() {
    local minutes="$1"
    date -d "+${minutes} minutes" '+%Y-%m-%dT%H:%M:%S%z'
}

# Convert ISO 8601 → `YYYY-MM-DD HH:MM:SS TZ` for display in the harvest
# log header and `show-allow-for-status` output. Containers run with
# `TZ=Europe/Prague` (or whichever the user's host uses) inherited at
# image build, so the rendered local time and TZ abbreviation match
# what the user sees on the host clock. Falls back to the raw ISO if
# `date -d` can't parse — defensive only, our writers always emit
# canonical shape.
allow_for::human_time() {
    local iso="$1"
    [ -z "$iso" ] && { printf '\n'; return 0; }
    date -d "$iso" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || printf '%s\n' "$iso"
}

# Human-friendly "Xm Ys remaining" for status output. Negative deltas
# print as "0s remaining" rather than negative — the teardown daemon will
# pick the window up on its next heartbeat.
allow_for::format_remaining() {
    local expires_at="$1"
    local exp now diff m s
    exp=$(date -d "$expires_at" +%s 2>/dev/null) || { printf 'unknown\n'; return 0; }
    now=$(date +%s)
    diff=$((exp - now))
    [ "$diff" -lt 0 ] && diff=0
    m=$((diff / 60))
    s=$((diff % 60))
    printf '%dm %02ds\n' "$m" "$s"
}
