#!/bin/bash
set -euo pipefail

# Container entrypoint with root → node privilege drop.
#
# Container starts as UID 0 via `docker run --user 0`. This script's root
# phase runs the only operations that require root (firewall, host-home
# symlink, system gitconfig), then exec's runuser to drop to node. Once
# dropped, PID 1 is node and there is no path back to root from inside the
# container — there are no NOPASSWD sudoers entries and no setuid bridges.
# See docs/adr/0003 for the security rationale.

if [ "$(id -u)" = "0" ]; then
    # Stage host gitconfig as system-wide config. Bind-mounted gitconfig
    # files trigger "Device busy" when VS Code/Cursor credential helpers
    # rewrite them; copying to /etc/gitconfig sidesteps the bind mount.
    cp /home/node/.gitconfig-host /etc/gitconfig 2>/dev/null || true

    # Volumes for IDE servers may be created as root on first mount.
    chown node:node /home/node/.cursor-server /home/node/.vscode-server 2>/dev/null || true

    # Claude plugin registry stores absolute paths rooted in the host home
    # (e.g. /home/<host-user>/.claude/plugins/cache/...). Without this
    # symlink those paths don't resolve inside the container. See ADR 0002.
    if [ -n "${HOST_HOME:-}" ] && [ "$HOST_HOME" != "/home/node" ] && [ ! -e "$HOST_HOME" ]; then
        mkdir -p "$(dirname "$HOST_HOME")"
        ln -sfn /home/node "$HOST_HOME"
    fi

    /usr/local/bin/init-firewall.sh

    exec runuser -u node -- "$0" "$@"
fi

# Node phase: keep PID 1 alive with graceful shutdown for inner DinD.
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

# bash ignores signals during foreground sleep; run sleep in background and wait.
while true; do
    sleep 60 &
    wait $! || true
done
