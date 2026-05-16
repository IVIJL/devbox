#!/bin/bash
set -euo pipefail

# =============================================================================
# teardown-allow-for-window — close an Allow-for window (ADR 0009)
# =============================================================================
# Runs inside a devbox container as root. Two modes:
#
#   daemon   (no args)  — heartbeat loop; tears down when sentinel expires.
#                         Forked by start-allow-for-window and detached via
#                         setsid so the docker-exec session exit doesn't kill it.
#   immediate (--now)   — invoked by `devbox allow-for --stop`. Kills the
#                         daemon first, then runs the teardown right away.
#
# A teardown writes the harvest log, reverses the firewall changes,
# deletes the sentinel, and drops a notification request file for the
# host-side delivery script (Phase 3).
# =============================================================================

# shellcheck source-path=SCRIPTDIR/..
# shellcheck source=lib/allow-for.sh
source /usr/local/share/devbox/lib/allow-for.sh

MODE="daemon"
HEARTBEAT_SECONDS=5
LOCK_FILE="/var/run/devbox-allow-for.lock"

case "${1:-}" in
    --now)   MODE="now" ;;
    --help|-h)
        sed -n '4,18p' "$0"
        exit 0
        ;;
    "")      MODE="daemon" ;;
    *)
        echo "ERROR: unknown argument '$1' (expected: --now or empty)" >&2
        exit 2
        ;;
esac

# --- Teardown core -----------------------------------------------------------
# Single source of truth for "close the window". Called by both modes under
# the flock; reads everything from the sentinel that exists at call time.
#
# $1: reason marker written into the harvest log header. One of
#     "expired"     — normal end-of-window, daemon path.
#     "stopped"     — user ran `--stop`.
#     "interrupted" — sentinel was already expired when daemon woke (e.g.
#                     container was paused / clock jumped).
do_teardown() {
    local reason="$1"
    local started_at expires_at container log_start_byte
    started_at=$(allow_for::get_field started_at || echo "unknown")
    expires_at=$(allow_for::get_field expires_at || echo "unknown")
    container=$(allow_for::get_field container || echo "unknown")
    log_start_byte=$(allow_for::get_field log_start_byte || echo 0)

    # Filename-safe variant of started_at: strip colons that confuse
    # Windows tooling when File Explorer opens the file via \\wsl$\... .
    # Drop the timezone offset's sign-prefix `+`/`-` collision with the
    # date separator by replacing colons only — `2026-05-16T07-30-15+0200`
    # stays unambiguous.
    local ts_safe="${started_at//:/-}"
    local log_path="${ALLOW_FOR_LOG_DIR}/${container}-${ts_safe}.log"

    mkdir -p "$ALLOW_FOR_LOG_DIR" 2>/dev/null || true

    # Harvest aggregation runs against the post-restart byte offset
    # captured at window open. An empty result is normal — the user may
    # have closed the window before anything outside the allowlist was
    # queried.
    local domains domain_count top_lines
    domains=$(allow_for::harvest_domains "$log_start_byte" || true)
    domain_count=0
    [ -n "$domains" ] && domain_count=$(printf '%s\n' "$domains" | wc -l)

    # Timestamps are rendered in human-readable form here (TZ-named, no
    # `T` separator) because this file is opened by the user via the
    # Windows toast click. Sentinel + pending JSON keep the ISO 8601
    # shape (machine-parseable). Container inherits host TZ via the
    # `TZ` env baked into the image, so the displayed local time and
    # TZ abbreviation match the user's host clock.
    {
        echo "# devbox allow-for harvest log"
        echo "container:   $container"
        echo "started_at:  $(allow_for::human_time "$started_at")"
        echo "expires_at:  $(allow_for::human_time "$expires_at")"
        echo "ended_at:    $(allow_for::human_time "$(allow_for::now_iso)")"
        echo "reason:      $reason"
        echo "domain_count: $domain_count"
        echo "# ----------------------------------------------------------------"
        if [ -n "$domains" ]; then
            printf '%s\n' "$domains"
        else
            echo "# (no non-allowlist domains were queried during the window)"
        fi
    } > "$log_path"
    chmod 0644 "$log_path"

    # Reverse the firewall state in setup order's mirror image. Each step
    # is best-effort: if init-firewall already cleaned up (rare path
    # through container restart), we still want the sentinel removed.
    rm -f "$ALLOW_FOR_DNSMASQ_CONF"
    /usr/local/bin/devbox-firewall-reload >/dev/null 2>&1 || true
    iptables -D OUTPUT -m set --match-set "$ALLOW_FOR_IPSET" dst -j ACCEPT 2>/dev/null || true
    ipset destroy "$ALLOW_FOR_IPSET" 2>/dev/null || true

    rm -f "$ALLOW_FOR_SENTINEL"

    # Build the top-3 list for the toast body — most-queried, then
    # alphabetical for ties. The dnsmasq log has one line per query, so
    # `sort | uniq -c | sort -rn` ranks correctly.
    top_lines=""
    if [ -n "$domains" ]; then
        local sb=$((log_start_byte + 1))
        top_lines=$(tail -c "+${sb}" "$ALLOW_FOR_DNSMASQ_QUERIES" 2>/dev/null \
            | grep -oP "query\[(A|AAAA)\] \K[^ ]+" \
            | grep -Fxf <(printf '%s\n' "$domains") \
            | sort | uniq -c | sort -rn -k1,1 -k2,2 \
            | awk '{print $2}' | head -3 | tr '\n' '|' | sed 's/|$//' || true)
    fi

    # Notification handoff for Phase 3. Pending JSON files are picked up
    # by the host-side delivery script on the next `devbox` invocation
    # (or by a one-shot watcher started alongside the window). Writing
    # the file is fire-and-forget — if no delivery runs, the harvest log
    # is still the canonical record.
    #
    # The pending dir is host-user-owned (see ensure-allow-for-host-state.sh)
    # so the deliver script can rename-claim atomically; the file itself
    # is still written as root:root 0644, so its CONTENTS can't be forged
    # mid-flight by the in-container node user. If the pending dir is
    # missing (pre-Phase-3 install upgraded without `devbox update`), skip
    # the handoff — the harvest log is canonical and the next update will
    # provision the dir.
    if [ -d "$ALLOW_FOR_PENDING_DIR" ] && [ -d "$ALLOW_FOR_TMP_DIR" ]; then
        local pending="${ALLOW_FOR_PENDING_DIR}/.pending-${container}-${ts_safe}.json"
        # Atomic publish via root-only scratch dir + cross-subdir rename.
        #
        # The pending dir is intentionally host-user-writable (= the
        # in-container node user, our adversary) so the host deliver
        # script can rename-claim notifications. That makes ANY file
        # we create inside it race-able: between mktemp's create and
        # the next `cat >` reopen, the attacker can unlink the tempfile
        # and replace it with a symlink to /etc/shadow, then root's
        # write follows the link.
        #
        # Solution: write the tempfile in $ALLOW_FOR_TMP_DIR — same
        # bind mount (so rename(2) doesn't EXDEV), but root-owned 0700
        # with a root-owned parent (no rmdir-and-recreate-as-node game).
        # The attacker cannot see the tempfile names, cannot create
        # files in there, cannot relocate the dir itself.
        #
        # The final `mv` is rename(2): atomic on same-filesystem; if
        # the destination is a symlink left by the attacker, rename
        # REPLACES the link rather than following it. Mode and
        # ownership are preserved, so the host-side deliver script
        # can still read the published JSON.
        local pending_tmp
        if pending_tmp=$(mktemp "${ALLOW_FOR_TMP_DIR}/pending.XXXXXXXXXX"); then
            cat > "$pending_tmp" <<EOF
{
  "container": "${container}",
  "log_path": "${log_path}",
  "started_at": "${started_at}",
  "ended_at": "$(allow_for::now_iso)",
  "reason": "${reason}",
  "domain_count": ${domain_count},
  "top_domains": "${top_lines}"
}
EOF
            chmod 0644 "$pending_tmp"
            # If mv fails (target is a node-owned directory, EXDEV
            # because someone broke the mount layout, etc.), don't
            # leave the tmpfile behind to leak. The harvest log is
            # canonical regardless.
            mv "$pending_tmp" "$pending" 2>/dev/null || rm -f "$pending_tmp"
        fi
    fi

    printf 'Allow-for window closed for %s (reason=%s, %d domains captured) — %s\n' \
        "$container" "$reason" "$domain_count" "$log_path"
}

# --- Immediate mode ----------------------------------------------------------
# `--stop`: kill the daemon (it owns the heartbeat sleep) so it can't race
# with our teardown, then run teardown under the lock. If no sentinel
# exists, this is a no-op success — the user expected the window closed,
# and it is.
if [ "$MODE" = "now" ]; then
    if ! allow_for::sentinel_exists; then
        echo "No active allow-for window."
        exit 0
    fi

    daemon_pid=$(allow_for::get_field daemon_pid || echo "0")
    if [ -n "$daemon_pid" ] && [ "$daemon_pid" != "0" ] && kill -0 "$daemon_pid" 2>/dev/null; then
        kill "$daemon_pid" 2>/dev/null || true
        # Brief wait so the daemon actually exits before we touch its
        # state. 1 s is plenty given the 5 s heartbeat (the daemon
        # spends most of its time in sleep, which exits immediately on
        # SIGTERM).
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$daemon_pid" 2>/dev/null || break
            sleep 0.1
        done
    fi

    exec 9>"$LOCK_FILE"
    flock 9
    # Re-check under the lock: the daemon may have completed its own
    # teardown between our sentinel check and the kill (or our kill may
    # have arrived just as the daemon was already exiting normally).
    # Without this, we'd write a phantom harvest log with "unknown"
    # fields.
    if ! allow_for::sentinel_exists; then
        echo "Allow-for window already closed."
        exit 0
    fi
    do_teardown stopped
    exit 0
fi

# --- Daemon mode -------------------------------------------------------------
# Loop: re-read the sentinel every heartbeat (5 s) so reset-clock updates
# take effect quickly and `--stop` can interrupt by deleting the sentinel
# out from under us. Exit cleanly if the sentinel disappears (another
# teardown raced ahead).
#
# SIGTERM from `--stop` exits the loop immediately because `sleep` returns
# non-zero on signal; we don't `wait` on the sleep, so the trap-less default
# is sufficient.
while allow_for::sentinel_exists; do
    if allow_for::is_expired; then
        exec 9>"$LOCK_FILE"
        flock 9
        # Re-check under the lock: an `--stop` invocation could have
        # taken the lock and finished teardown while we were waiting.
        allow_for::sentinel_exists || exit 0
        do_teardown expired
        exit 0
    fi
    sleep "$HEARTBEAT_SECONDS"
done
