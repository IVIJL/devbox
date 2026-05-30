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

    # Container identity file (ADR 0011 Layer 1). Single source of truth
    # for "am I inside a devbox container, and which project?" — read by
    # the agent-context hook and the devbox skill's identity check. The
    # file's presence is the signal; the project field is consumed to
    # construct host-side command examples. Root-owned, world-readable.
    # Idempotent across container restarts: the redirect truncates the
    # existing file in place, so no orphan tmp files accumulate. `jq -n`
    # guarantees valid JSON regardless of project-name content (the value
    # is LDH-sanitised upstream per ADR 0005, but defence-in-depth keeps
    # any future relaxation of the sanitiser from producing malformed JSON).
    mkdir -p /etc/devbox
    # projectKey is the FULL host-path key for this Container's Project (ADR
    # 0014 issue 15): the MCP broker uses it to bind Project-scoped requests to
    # exactly this Container, defeating a basename collision between two Projects
    # (e.g. /work/a/api vs /work/b/api). It is the same absolute host path
    # docker-run.sh mounts the project at and exports as DEVBOX_PROJECT_HOST_PATH
    # — non-secret identity metadata. Absent for non-project invocations; the
    # broker then falls back to the (weaker) Project-name guard. Emitted only
    # when set so existing identity-file readers ignoring it are unaffected.
    jq -n \
        --arg project "${DEVBOX_PROJECT_NAME:-unknown}" \
        --arg projectKey "${DEVBOX_PROJECT_HOST_PATH:-}" \
        '{project: $project} + (if $projectKey == "" then {} else {projectKey: $projectKey} end)' \
        > /etc/devbox/identity.json
    chmod 0644 /etc/devbox/identity.json

    # Container MCP broker (ADR 0014, issue 15). Start the always-on broker as
    # the dedicated unprivileged `devbox-mcp` account BEFORE dropping PID 1 to
    # node, so MCP servers run behind a UID boundary the agent cannot cross.
    #
    # The drop MUST reset the full credential set, not just the UID:
    #   --reuid alone would leave the broker with root's GID and supplementary
    #   groups, re-exposing group-readable root-owned files — the opposite of
    #   what a credential-isolation component needs. --regid devbox-mcp
    #   --init-groups sets the primary group to devbox-mcp and reinitialises
    #   supplementary groups from /etc/group for that account, so the broker
    #   holds ONLY devbox-mcp's own groups (ADR 0014). Owned by devbox-mcp, the
    #   broker is unsignalable / unptraceable by node.
    #
    # The socket dir is created here (root) and handed to devbox-mcp so the
    # broker can create its socket; it lives OUTSIDE any 0700 secret dir
    # (connecting exposes only a stdio pipe, no credential). 0750 group-owned
    # devbox-mcp lets node (a member of the devbox-mcp group) traverse to the
    # socket without granting world access. The broker always runs, even with no
    # profile, so a server imported into a running Container works next session.
    #
    # The PRIVATE staged secret dir is created 0700 devbox-mcp:devbox-mcp — node
    # cannot traverse it. It is EMPTY in this issue (issue 16 stages per-server
    # secrets here, root-side, into 0400 devbox-mcp files); the broker reads
    # secret VALUES only from here, never from the node-owned profile mount, so a
    # secret-declaring server cleanly reports missing env until issue 16.
    if id devbox-mcp >/dev/null 2>&1; then
        install -d -o devbox-mcp -g devbox-mcp -m 0750 /run/devbox-mcp
        install -d -o devbox-mcp -g devbox-mcp -m 0700 /run/devbox-mcp/secrets
        # setpriv switches credentials but PRESERVES the (root) environment, so
        # the broker — and every MCP server it spawns as devbox-mcp — would
        # otherwise inherit root's HOME and npm settings and try to write under
        # node-owned/root-owned paths. `env -i` starts from a clean slate and we
        # set exactly devbox-mcp's runtime env:
        #   * HOME + npm/npx cache under devbox-mcp's own writable HOME, so
        #     on-demand `npx` MCP servers run under the service account;
        #   * XDG_CONFIG_HOME -> the bind-mounted host MCP PROFILE so
        #     mcp.profile.config_root() reads the same (secret-free) store the
        #     host writes — NOT an empty store under devbox-mcp's HOME;
        #   * DEVBOX_MCP_SECRETS_DIR -> the private staged secret dir above, the
        #     ONLY place the broker reads secret VALUES from;
        #   * a minimal PATH including npm-global bin (npx/node) + system dirs.
        setpriv --reuid=devbox-mcp --regid=devbox-mcp --init-groups \
            -- env -i \
                HOME=/home/devbox-mcp \
                USER=devbox-mcp \
                LOGNAME=devbox-mcp \
                XDG_CONFIG_HOME=/home/node/.config \
                DEVBOX_MCP_SECRETS_DIR=/run/devbox-mcp/secrets \
                npm_config_cache=/home/devbox-mcp/.npm \
                XDG_CACHE_HOME=/home/devbox-mcp/.cache \
                PATH=/usr/local/share/npm-global/bin:/usr/local/bin:/usr/bin:/bin \
                /usr/local/bin/devbox-mcp-broker &
    else
        echo "devbox: WARNING: devbox-mcp account missing; MCP broker not started." >&2
    fi

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
