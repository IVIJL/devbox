#!/bin/bash
set -euo pipefail

# Container entrypoint with root → node privilege drop.
#
# Container starts as UID 0 via `docker run --user 0`. This script's root
# phase runs the only operations that require root (firewall, host-home
# symlink, system gitconfig), then exec's setpriv to drop to node. setpriv
# performs a clean execve after switching credentials (no fork), so PID 1
# becomes this script running as node — no residual root parent in the
# process tree. Combined with no NOPASSWD sudoers entries and no setuid
# bridges, there is no path back to root from inside the container.
# See docs/adr/0003 for the security rationale.

if [ "$(id -u)" = "0" ]; then
    # Stage host gitconfig as system-wide config. Bind-mounted gitconfig
    # files trigger "Device busy" when VS Code/Cursor credential helpers
    # rewrite them; copying to /etc/gitconfig sidesteps the bind mount.
    cp /home/node/.gitconfig-host /etc/gitconfig 2>/dev/null || true

    # Volumes for IDE servers may be created as root on first mount.
    chown node:node /home/node/.cursor-server /home/node/.vscode-server 2>/dev/null || true

    # Bridge $HOST_HOME (host user's home dir) to /home/node (container user's
    # home, where the bind mounts live). Two requirements collide:
    #
    # 1. Claude's plugin registry stores absolute paths under
    #    /home/<host-user>/.claude/... (see ADR 0002), so those paths must
    #    resolve into the bind mount.
    # 2. Phase 2 (ADR 0004) bind-mounts each project at its literal host path
    #    (e.g. /home/<host-user>/Projekty/X) so getcwd(2) inside the
    #    container returns the host path — needed for plugin/session parity.
    #    A whole-dir symlink at /home/<host-user> would make the kernel
    #    canonicalise getcwd() to /home/node/... and defeat parity.
    #
    # Solution: $HOST_HOME is a real directory whose contents mirror
    # /home/node via per-entry symlinks. Project mounts live as real subdirs
    # alongside the mirror, so their canonical paths match the host.
    if [ -n "${HOST_HOME:-}" ] && [ "$HOST_HOME" != "/home/node" ]; then
        # Heal pre-Phase-2 layout (whole-dir symlink) by replacing it.
        if [ -L "$HOST_HOME" ]; then
            rm -f "$HOST_HOME"
        fi
        mkdir -p "$HOST_HOME"
        chown node:node "$HOST_HOME"
        shopt -s dotglob nullglob
        for entry in /home/node/*; do
            name=$(basename "$entry")
            [ -e "$HOST_HOME/$name" ] || [ -L "$HOST_HOME/$name" ] || \
                ln -sfn "$entry" "$HOST_HOME/$name"
        done
        shopt -u dotglob nullglob
    fi

    /usr/local/bin/init-firewall.sh

    exec setpriv --reuid=node --regid=node --init-groups -- "$0" "$@"
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
