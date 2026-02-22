#!/bin/bash
set -euo pipefail

# =============================================================================
# Devbox - Docker run convenience script
# =============================================================================
# Usage:
#   devbox                                  # mount current directory as /workspace
#   devbox /path/to/project                 # mount project as /workspace
#   devbox nazev                            # attach to running devbox-nazev container
#   devbox ls                               # list running devbox containers
#   devbox stop <nazev>                     # stop container and remove docker volume
#
# Install globally:
#   sudo ln -s /path/to/devbox/docker-run.sh /usr/local/bin/devbox
# =============================================================================

IMAGE="vlcak/devbox:latest"
SSH_WARNING=""

# --- Helper functions --------------------------------------------------------

sanitize() {
    echo "$1" | tr -cs 'a-zA-Z0-9_.-' '-' | sed 's/^-//;s/-$//'
}

attach_to_container() {
    local name="$1"
    echo "Attaching to running container: $name"
    exec docker exec -it -w /workspace "$name" zsh
}

list_running_containers() {
    docker ps --filter "name=^devbox-" --format 'table {{.Names}}\t{{.Status}}\t{{.RunningFor}}'
}

# Interactive container picker
# $1 = prompt text, $2 = optionally "with_all" to add "stop all" option
# Returns selected name on stdout, returns 1 on cancel/empty
pick_container() {
    local prompt="$1"
    local with_all="${2:-}"
    local running
    running=$(docker ps --filter "name=^devbox-" --format '{{.Names}}')

    if [ -z "$running" ]; then
        echo "Žádné běžící devbox kontejnery." >&2
        return 1
    fi

    local options="$running"
    if [ "$with_all" = "with_all" ]; then
        options=$(printf '%s\n%s' "$running" "* Zastavit všechny")
    fi

    if command -v fzf &>/dev/null; then
        echo "$options" | fzf --prompt="$prompt" || return 1
    else
        # Fallback: numbered menu
        echo "" >&2
        local i=1
        while IFS= read -r line; do
            echo "  $i) $line" >&2
            i=$((i + 1))
        done <<< "$options"
        echo "" >&2
        printf "%s" "$prompt" >&2
        read -r choice
        sed -n "${choice}p" <<< "$options"
    fi
}

# --- Subcommand parsing ------------------------------------------------------

case "${1:-}" in
    ls)    MODE="ls";   shift ;;
    stop)  MODE="stop"; shift; PROJECT_FILTER="${1:-}" ;;
    *)     MODE="auto" ;;
esac

# --- devbox ls ---------------------------------------------------------------

if [ "$MODE" = "ls" ]; then
    list_running_containers
    exit 0
fi

# --- devbox stop [nazev] -----------------------------------------------------

if [ "$MODE" = "stop" ]; then
    if [ -n "$PROJECT_FILTER" ]; then
        name="devbox-${PROJECT_FILTER}"
        if docker ps --filter "name=^${name}$" --format '{{.ID}}' | grep -q .; then
            docker stop "$name" > /dev/null
            docker rm "$name" > /dev/null
            docker volume rm "devbox-${PROJECT_FILTER}-docker" > /dev/null
            echo "Zastaven: $name"
            exit 0
        fi
        echo "Kontejner $name neběží." >&2
    fi
    # No argument or container not found → interactive selection
    selected=$(pick_container "Zastavit kontejner: " "with_all") || exit 1
    if [ "$selected" = "* Zastavit všechny" ]; then
        docker ps --filter "name=^devbox-" --format '{{.Names}}' | while IFS= read -r c; do
            proj="${c#devbox-}"
            docker stop "$c" > /dev/null
            docker rm "$c" > /dev/null
            docker volume rm "devbox-${proj}-docker" > /dev/null
            echo "Zastaven: $c"
        done
    else
        proj="${selected#devbox-}"
        docker stop "$selected" > /dev/null
        docker rm "$selected" > /dev/null
        docker volume rm "devbox-${proj}-docker" > /dev/null
        echo "Zastaven: $selected"
    fi
    exit 0
fi

# --- Auto mode: create or attach ---------------------------------------------

if [ -d "${1:-.}" ]; then
    # Argument is a directory (or none → CWD) → create/attach mode
    PROJECT_PATH="$(realpath "${1:-.}")"
    PROJECT_NAME="$(basename "$PROJECT_PATH")"
    CONTAINER_NAME="devbox-$(sanitize "$PROJECT_NAME")"

    if docker ps --filter "name=^${CONTAINER_NAME}$" --format '{{.ID}}' | grep -q .; then
        attach_to_container "$CONTAINER_NAME"
        # exec → script ends here
    fi

    # Container not running → create new one (detached) below
else
    # Argument is not a directory → attach by name
    CONTAINER_NAME="devbox-${1}"
    if docker ps --filter "name=^${CONTAINER_NAME}$" --format '{{.ID}}' | grep -q .; then
        attach_to_container "$CONTAINER_NAME"
    else
        echo "Kontejner $CONTAINER_NAME neběží." >&2
        selected=$(pick_container "Vyber kontejner: ") || exit 1
        attach_to_container "$selected"
    fi
fi

# --- SSH agent setup (only when creating a new container) --------------------

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
    eval "$(keychain --eval --quiet --agents ssh)"
fi

# Final fallback: start plain ssh-agent
if [ -z "${SSH_AUTH_SOCK:-}" ]; then
    echo "Starting SSH agent..."
    eval "$(ssh-agent -s)" > /dev/null
    echo "  Add your keys with: ssh-add"
fi

# Ensure agent has keys loaded
if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
    if ! ssh-add -l &>/dev/null; then
        echo "SSH agent has no keys, adding default keys..."
        ssh-add
    fi
fi

# --- Build docker arguments -------------------------------------------------

DOCKER_ARGS=(
    --hostname "$PROJECT_NAME"
    --cap-add=SYS_ADMIN
    --cap-add=NET_ADMIN
    --cap-add=NET_RAW
    --security-opt seccomp=unconfined
    --security-opt apparmor=unconfined
    --security-opt systempaths=unconfined
    --device=/dev/net/tun
    --device=/dev/fuse
    # Per-project volumes
    -v "devbox-${PROJECT_NAME}-history:/home/node/.local/share/atuin"
    -v "devbox-${PROJECT_NAME}-docker:/home/node/.local/share/docker"
    # Shared volumes
    -v devbox-claude-config:/home/node/.claude
    -v devbox-nvim-data:/home/node/.local/share/nvim
    -v devbox-cursor-server:/home/node/.cursor-server
    -e CLAUDE_CONFIG_DIR=/home/node/.claude
    # Git config from host (system-level so Cursor/VS Code can write to ~/.gitconfig)
    -v "$HOME/.gitconfig:/etc/gitconfig:ro"
    # SSH config only (no private keys)
    -v "$HOME/.ssh/config:/home/node/.ssh/config:ro"
    -v "$HOME/.ssh/known_hosts:/home/node/.ssh/known_hosts:ro"
)

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

# Mount workspace
DOCKER_ARGS+=(-v "$PROJECT_PATH:/workspace")

# --- Start detached container ------------------------------------------------

# Print warnings just before starting container (so they're visible)
if [ -n "$SSH_WARNING" ]; then
    echo "$SSH_WARNING"
fi

echo "Mounting project: $PROJECT_PATH -> /workspace ($CONTAINER_NAME)"
echo "Starting devbox..."

# Start container in background
docker run -d --name "$CONTAINER_NAME" "${DOCKER_ARGS[@]}" "$IMAGE" tail -f /dev/null

# Run init scripts inside the container
docker exec "$CONTAINER_NAME" bash -c \
    'sudo /usr/local/bin/init-firewall.sh && /usr/local/bin/start-rootless-docker.sh && /usr/local/bin/setup-chezmoi.sh && /usr/local/bin/setup-claude.sh'

# Attach first interactive session
exec docker exec -it -w /workspace "$CONTAINER_NAME" zsh
