#!/bin/bash
set -euo pipefail

# =============================================================================
# Devbox - Docker run convenience script
# =============================================================================
# Usage:
#   devbox                                  # mount current directory as /workspace
#   devbox /path/to/project                 # mount project as /workspace
#
# Install globally:
#   sudo ln -s /path/to/devbox/docker-run.sh /usr/local/bin/devbox
# =============================================================================

IMAGE="vlcak/devbox:latest"
CONTAINER_NAME="devbox"
SSH_WARNING=""

DOCKER_ARGS=(
    --rm -it
    --name "$CONTAINER_NAME"
    --cap-add=SYS_ADMIN
    --cap-add=NET_ADMIN
    --cap-add=NET_RAW
    --security-opt seccomp=unconfined
    --security-opt apparmor=unconfined
    --security-opt systempaths=unconfined
    --device=/dev/net/tun
    --device=/dev/fuse
    # Persistent volumes
    -v devbox-bashhistory:/commandhistory
    -v devbox-claude-config:/home/node/.claude
    -v devbox-docker:/home/node/.local/share/docker
    -v devbox-nvim-data:/home/node/.local/share/nvim
    -v devbox-cursor-server:/home/node/.cursor-server
    -e CLAUDE_CONFIG_DIR=/home/node/.claude
    # Git config from host (system-level so Cursor/VS Code can write to ~/.gitconfig)
    -v "$HOME/.gitconfig:/etc/gitconfig:ro"
    # SSH config only (no private keys)
    -v "$HOME/.ssh/config:/home/node/.ssh/config:ro"
    -v "$HOME/.ssh/known_hosts:/home/node/.ssh/known_hosts:ro"
)

# SSH agent recovery - try to restore agent before giving up
if [ -z "${SSH_AUTH_SOCK:-}" ]; then
    # Try keychain's saved agent info
    keychain_sh="$HOME/.keychain/$(hostname)-sh"
    if [ -f "$keychain_sh" ]; then
        # shellcheck disable=SC1090
        . "$keychain_sh"
    fi
fi

# Verify agent is alive (socket path set but socket is dead)
if [ -n "${SSH_AUTH_SOCK:-}" ] && [ ! -S "$SSH_AUTH_SOCK" ]; then
    unset SSH_AUTH_SOCK
fi

# If still no agent, try to start one via keychain
if [ -z "${SSH_AUTH_SOCK:-}" ] && command -v keychain &>/dev/null; then
    eval $(keychain --eval --quiet --agents ssh)
fi

# Final fallback: start plain ssh-agent
if [ -z "${SSH_AUTH_SOCK:-}" ]; then
    echo "Starting SSH agent..."
    eval $(ssh-agent -s) > /dev/null
    echo "  Add your keys with: ssh-add"
fi

# SSH agent forwarding (private keys never enter the container)
if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
    DOCKER_ARGS+=(
        -v "$SSH_AUTH_SOCK:/tmp/ssh-agent.sock"
        -e SSH_AUTH_SOCK=/tmp/ssh-agent.sock
    )
else
    SSH_WARNING="WARNING: SSH agent not available - SSH forwarding won't work inside devbox
  Ensure keychain or ssh-agent is running, then restart devbox"
fi

# Pass through API key
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    DOCKER_ARGS+=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
fi

# Pass through extra domains
if [ -n "${DEVBOX_EXTRA_DOMAINS:-}" ]; then
    DOCKER_ARGS+=(-e "DEVBOX_EXTRA_DOMAINS=$DEVBOX_EXTRA_DOMAINS")
fi

# Auto-detect NTFY_TOKEN from host's Claude hooks if not set
if [ -z "${NTFY_TOKEN:-}" ] && [ -d "$HOME/.claude/hooks" ]; then
    NTFY_TOKEN=$(grep -ohm1 'TOKEN="tk_[^"]*"' "$HOME/.claude/hooks/"*.sh 2>/dev/null | head -1 | cut -d'"' -f2 || true)
fi

if [ -n "${NTFY_TOKEN:-}" ]; then
    DOCKER_ARGS+=(-e "NTFY_TOKEN=$NTFY_TOKEN")
fi

# Workspace: argument or current directory
PROJECT_PATH=$(realpath "${1:-$PWD}")
if [ ! -d "$PROJECT_PATH" ]; then
    echo "ERROR: Directory $PROJECT_PATH does not exist"
    exit 1
fi
echo "Mounting project: $PROJECT_PATH -> /workspace"
DOCKER_ARGS+=(-v "$PROJECT_PATH:/workspace")

# Print warnings just before starting container (so they're visible)
if [ -n "$SSH_WARNING" ]; then
    echo "$SSH_WARNING"
fi

echo "Starting devbox..."
exec docker run "${DOCKER_ARGS[@]}" "$IMAGE" \
    zsh -c 'sudo /usr/local/bin/init-firewall.sh && /usr/local/bin/start-rootless-docker.sh && /usr/local/bin/setup-chezmoi.sh && /usr/local/bin/setup-claude.sh && exec zsh'
