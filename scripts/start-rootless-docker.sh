#!/bin/bash
set -euo pipefail

# =============================================================================
# Start rootless Docker daemon (runs as node user, no privileges needed)
# =============================================================================

# Ensure XDG_RUNTIME_DIR exists (may be tmpfs, gets wiped on restart)
mkdir -p "$XDG_RUNTIME_DIR"

SOCKET="$XDG_RUNTIME_DIR/docker.sock"

# Skip if already running
if [ -S "$SOCKET" ] && docker info >/dev/null 2>&1; then
    echo "Rootless Docker is already running."
    exit 0
fi

echo "Starting rootless Docker daemon..."
dockerd-rootless.sh >/tmp/dockerd-rootless.log 2>&1 &

# Wait for the socket to appear
TIMEOUT=30
for i in $(seq 1 "$TIMEOUT"); do
    if [ -S "$SOCKET" ]; then
        echo "Rootless Docker started successfully (${i}s)."
        exit 0
    fi
    sleep 1
done

echo "ERROR: Rootless Docker failed to start within ${TIMEOUT}s."
echo "Check /tmp/dockerd-rootless.log for details."
exit 1
