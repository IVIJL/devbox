#!/bin/bash
set -euo pipefail

# =============================================================================
# Devbox entrypoint — PID 1 with graceful shutdown
# =============================================================================
# Traps SIGTERM (sent by docker stop / host reboot) and gracefully stops
# inner DinD containers before exiting, preventing database corruption.

shutdown_handler() {
    echo "devbox: SIGTERM received, stopping inner containers..."
    if [ -S "$XDG_RUNTIME_DIR/docker.sock" ] && docker info >/dev/null 2>&1; then
        inner=$(docker ps --format "{{.ID}} {{.Names}}" 2>/dev/null)
        if [ -n "$inner" ]; then
            while read -r cid cname; do
                echo "  Stopping: $cname ($cid)"
                docker stop -t 30 "$cid" >/dev/null 2>&1 || true
            done <<< "$inner"
        fi
        echo "devbox: Inner containers stopped."
    fi
    exit 0
}

trap shutdown_handler SIGTERM SIGINT

# Keep container alive — sleep in background + wait allows signal handling
# (bash ignores signals during foreground sleep)
while true; do
    sleep 60 &
    wait $! || true
done
