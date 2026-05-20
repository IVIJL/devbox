#!/bin/bash
# Devbox auto-connect wrapper for the upstream `agent-browser` CLI.
#
# `devbox agent-browser start` (on the host) sets up a socat bridge in
# the container that listens on 127.0.0.1:9222 and forwards CDP to the
# Host agent Chrome. The npm-installed `agent-browser` binary doesn't
# know about that bridge, so without intervention `agent-browser open
# <url>` falls back to auto-launching a local Chrome — which devbox
# containers don't ship — and fails with "Chrome not found".
#
# This wrapper sits in /usr/local/bin/agent-browser (ahead of
# /usr/local/share/npm-global/bin in PATH) and issues a one-shot
# `connect 9222` before delegating to the upstream binary so the next
# command lands on the bridge. The connect call is cached under /tmp
# for this container's lifetime (sentinel wiped on restart), so the WS
# handshake happens at most once per container boot.
#
# Scope: targeted at the common shape `agent-browser <verb> [args]`
# and `agent-browser --session NAME <verb> [args]`. Power-user
# invocations that put global flags AFTER the verb, use uncommon
# value-bearing options (`--state`, `--profile`, `--config`), or rely
# on boolean globals the upstream CLI doesn't document (`--debug`,
# `--ignore-https-errors`, etc.) may bypass auto-connect — in that
# case the user can manually run
#   `agent-browser <global-flags> connect 9222`
# once per session and the upstream CLI takes it from there.
set -euo pipefail

REAL="/usr/local/share/npm-global/bin/agent-browser"
BRIDGE_URL="http://127.0.0.1:9222/json/version"

# Resolve the upstream CLI's `--session NAME` (and AGENT_BROWSER_SESSION
# env equivalent) AND the actual subcommand in a single pass. The
# upstream CLI accepts many value-taking global options before the
# verb (`--session`, `--profile`, `--proxy`, `--config`, `--state`, ...
# — list keeps growing), so a fixed allowlist of value-takers is
# fragile. Invert it: ENUMERATE the booleans (`--auto-connect`,
# `--json`, `--allow-file-access`, ...) and treat every other `--flag`
# as value-taking. That way a future upstream value-flag still skips
# its operand safely; a new boolean would only over-consume one
# positional, which is recoverable.
session_name="${AGENT_BROWSER_SESSION:-default}"
op=""
expect_value=""
preargs=()
for arg in "$@"; do
    if [ -n "$expect_value" ]; then
        if [ "$expect_value" = "--session" ]; then
            session_name="$arg"
        fi
        preargs+=("$arg")
        expect_value=""
        continue
    fi
    case "$arg" in
        --session=*)
            session_name="${arg#--session=}"
            preargs+=("$arg")
            ;;
        # Boolean globals — no following value.
        --auto-connect|--allow-file-access|--json|--verbose|-v|--quiet|-q|--help|-h|--version)
            preargs+=("$arg")
            ;;
        # --flag=value form: value already attached, nothing to skip.
        --*=*)
            preargs+=("$arg")
            ;;
        # Every other long or short option takes a value next.
        --*|-[!-]*)
            preargs+=("$arg")
            expect_value="$arg"
            ;;
        *)
            # The first non-flag positional IS the subcommand.
            # Capture it and stop scanning — anything after is an
            # operand (URL, selector, text), not another verb. Without
            # this break the loop would mis-classify operands like
            # `agent-browser click close` or `find text connect` as
            # pass-through subcommands and skip auto-connect.
            op="$arg"
            break
            ;;
    esac
done

# Sanitise session_name into a filesystem-safe sentinel suffix so an
# adversarially crafted name (`../foo`, spaces) cannot redirect rm.
# A safe sentinel charset mirrors the broker's container-name policy.
safe_session="${session_name//[^A-Za-z0-9._-]/_}"
SENTINEL="/tmp/.agent-browser-devbox-connected-${safe_session}"

# Help/version/empty-argv exit early — those upstream modes never
# touch Chrome, so an auto-connect probe is wasted I/O.
if [ "$#" -eq 0 ]; then
    exec "$REAL"
fi
case "${1:-}" in
    -h|--help|--version)
        exec "$REAL" "$@"
        ;;
esac

# Subcommands that don't drive Chrome: pass through untouched.
# `disconnect`, `close`, and the undocumented `quit`/`exit` aliases all
# tear down the upstream session, so they additionally invalidate the
# cache — the next Chrome-bound call must re-issue `connect 9222`
# instead of skipping the preflight and silently falling through to
# auto-launch. `close --all` closes every upstream session, so it
# wipes every per-session sentinel (not just this invocation's).
case "$op" in
    disconnect)
        rm -f "$SENTINEL"
        exec "$REAL" "$@"
        ;;
    close|quit|exit)
        case " $* " in
            *" --all "*) rm -f /tmp/.agent-browser-devbox-connected-* ;;
            *)           rm -f "$SENTINEL" ;;
        esac
        exec "$REAL" "$@"
        ;;
    connect|skills|install|help|version)
        exec "$REAL" "$@"
        ;;
esac

# Idempotent pre-flight with stale-state detection.
#
# Each Chrome process emits a unique `webSocketDebuggerUrl` of the form
# `ws://127.0.0.1:9222/devtools/browser/<uuid>`. The upstream CLI caches
# that exact URL in its own state on `connect`; if the user restarts
# the session (`devbox agent-browser stop` → `start`, or the watchdog
# tears down a closed window and a new session comes up), the cached
# URL targets a dead Chrome process and every subsequent command fails
# even though port 9222 is up again with a different UUID.
#
# The sentinel therefore stores the WS URL we connected to, not just a
# yes/no marker. Before skipping connect we re-probe the bridge and
# compare: matching UUID = same Chrome, skip cheaply; mismatch =
# Chrome restarted under us, drop the sentinel and reconnect.
#
# Pre-verb global flags (`--state`, `--profile`, etc.) are forwarded
# into the connect call so the bridge gets recorded under the SAME
# state the real command will read from.
current_ws=""
if curl_out="$(curl -sf --max-time 1 "$BRIDGE_URL" 2>/dev/null)"; then
    # Extract the `"webSocketDebuggerUrl": "<url>"` snippet without
    # adding a jq dependency to the devbox image. Chrome pretty-prints
    # `/json/version` with whitespace around the colon, so the pattern
    # has to tolerate `:`, `: `, `:\t`, etc. The `|| true` on the
    # pipeline keeps `set -euo pipefail` from killing the wrapper when
    # the field is absent (older Chrome builds, partial responses) —
    # we degrade to "no UUID known", which the caller handles by
    # falling through to the upstream binary unchanged.
    current_ws="$(printf '%s' "$curl_out" \
        | grep -oE '"webSocketDebuggerUrl"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -1 || true)"
fi

if [ -f "$SENTINEL" ] && [ -n "$current_ws" ]; then
    cached_ws="$(cat "$SENTINEL" 2>/dev/null || true)"
    if [ "$cached_ws" != "$current_ws" ]; then
        rm -f "$SENTINEL"
    fi
fi

if [ ! -f "$SENTINEL" ] && [ -n "$current_ws" ]; then
    # Ensure `--session` is present even when the user relied on
    # AGENT_BROWSER_SESSION or the upstream default — the sentinel
    # is keyed on that resolved name, so the connect must match.
    connect_args=("${preargs[@]+"${preargs[@]}"}")
    case " ${connect_args[*]} " in
        *" --session "*|*" --session="*) ;;
        *) connect_args+=(--session "$session_name") ;;
    esac
    if "$REAL" "${connect_args[@]}" connect 9222 >/dev/null 2>&1; then
        printf '%s\n' "$current_ws" > "$SENTINEL"
    fi
    # Best-effort: if connect failed, fall through to the real
    # binary so its own "Chrome not found" message reaches the
    # user with the canonical install hint — better than masking
    # the failure here.
fi

exec "$REAL" "$@"
