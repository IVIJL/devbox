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
    -e CLAUDE_CONFIG_DIR=/home/node/.claude
    # Git config from host
    -v "$HOME/.gitconfig:/home/node/.gitconfig:ro"
    # SSH config only (no private keys)
    -v "$HOME/.ssh/config:/home/node/.ssh/config:ro"
    -v "$HOME/.ssh/known_hosts:/home/node/.ssh/known_hosts:ro"
)

# SSH agent forwarding (private keys never enter the container)
if [ -n "${SSH_AUTH_SOCK:-}" ]; then
    DOCKER_ARGS+=(
        -v "$SSH_AUTH_SOCK:/tmp/ssh-agent.sock"
        -e SSH_AUTH_SOCK=/tmp/ssh-agent.sock
    )
else
    echo "WARNING: SSH_AUTH_SOCK not set - SSH agent forwarding won't work"
    echo "  Start your agent with: eval \$(ssh-agent) && ssh-add"
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

echo "Starting devbox..."
exec docker run "${DOCKER_ARGS[@]}" "$IMAGE" \
    zsh -c 'sudo /usr/local/bin/init-firewall.sh && /usr/local/bin/start-rootless-docker.sh && /usr/local/bin/setup-chezmoi.sh && /usr/local/bin/setup-claude.sh && exec zsh'
