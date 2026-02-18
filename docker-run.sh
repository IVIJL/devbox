#!/bin/bash
set -euo pipefail

# =============================================================================
# Devbox - Docker run convenience script
# =============================================================================
# Usage:
#   ./docker-run.sh                        # standalone, persistent workspace volume
#   ./docker-run.sh /path/to/project       # mount project as /workspace
# =============================================================================

IMAGE="vlcak/devbox:latest"
CONTAINER_NAME="devbox"

DOCKER_ARGS=(
    --rm -it
    --name "$CONTAINER_NAME"
    --privileged
    # Persistent volumes
    -v devbox-bashhistory:/commandhistory
    -v devbox-claude-config:/home/node/.claude
    -v devbox-docker:/var/lib/docker
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

# Workspace: project mount or named volume
if [ -n "${1:-}" ]; then
    PROJECT_PATH=$(realpath "$1")
    if [ ! -d "$PROJECT_PATH" ]; then
        echo "ERROR: Directory $PROJECT_PATH does not exist"
        exit 1
    fi
    echo "Mounting project: $PROJECT_PATH -> /workspace"
    DOCKER_ARGS+=(-v "$PROJECT_PATH:/workspace")
else
    echo "Standalone mode: using persistent workspace volume"
    DOCKER_ARGS+=(-v devbox-workspace:/workspace)
fi

echo "Starting devbox..."
exec docker run "${DOCKER_ARGS[@]}" "$IMAGE" \
    zsh -c 'sudo /usr/local/bin/init-firewall.sh && sudo dockerd &>/var/log/dockerd.log & /usr/local/bin/setup-chezmoi.sh && exec zsh'
