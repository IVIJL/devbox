#!/bin/bash
set -euo pipefail

# =============================================================================
# Devbox — build script
# =============================================================================
# Run './build.sh --help' for usage information.
# =============================================================================

show_help() {
    cat <<'EOF'
Devbox — build script

Usage:
  ./build.sh                       Build image (uses cache)
  ./build.sh --no-cache            Full rebuild without cache
  ./build.sh --progress=plain      Show full build log
  ./build.sh --clean               Full reset + rebuild
  ./build.sh --uninstall           Full reset without rebuild

All other flags pass through to docker build.
Set DEVBOX_SUDO_PASSWORD env var for non-interactive builds.
EOF
    exit 0
}

case "${1:-}" in
    -h|--help) show_help ;;
esac

CLEAN=false
UNINSTALL=false
DOCKER_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --clean)     CLEAN=true ;;
        --uninstall) UNINSTALL=true ;;
        *)           DOCKER_ARGS+=("$arg") ;;
    esac
done

IMAGE="vlcak/devbox:latest"

# Full reset: volumes, cache, dangling images
full_reset() {
    # Stop and remove all devbox containers (including traefik) so volumes can be deleted
    CONTAINERS=$(docker ps -a --filter "name=^devbox-" --format '{{.Names}}' 2>/dev/null || true)
    if [ -n "$CONTAINERS" ]; then
        echo "Stopping devbox containers..."
        while IFS= read -r c; do
            docker stop -t 15 "$c" > /dev/null 2>&1 || true
            docker rm "$c" > /dev/null 2>&1 || true
            echo "  Removed: $c"
        done <<< "$CONTAINERS"
    fi

    VOLUMES=$(docker volume ls -q --filter "name=devbox-" 2>/dev/null || true)
    if [ -n "$VOLUMES" ]; then
        echo "Removing devbox volumes:"
        echo "$VOLUMES"
        # shellcheck disable=SC2086  # intentional word splitting — each volume name is a separate arg
        docker volume rm $VOLUMES || true
        # Verify deletion
        REMAINING=$(docker volume ls -q --filter "name=devbox-" 2>/dev/null || true)
        if [ -n "$REMAINING" ]; then
            echo "ERROR: Failed to remove volumes (containers still running?):"
            echo "$REMAINING"
            exit 1
        fi
        echo "All devbox volumes removed"
    else
        echo "No devbox volumes found"
    fi

    echo "Pruning all build cache..."
    docker builder prune --all -f 2>/dev/null || true

    echo "Pruning dangling images..."
    docker image prune -f 2>/dev/null || true

    echo ""
}

# --- Uninstall: full reset without rebuild -----------------------------------

if [ "$UNINSTALL" = true ]; then
    echo "=== Uninstall: full reset ==="
    full_reset

    # Remove devbox image
    if docker images -q "$IMAGE" 2>/dev/null | grep -q .; then
        echo "Removing devbox image..."
        docker rmi "$IMAGE" 2>/dev/null || true
    fi

    # Remove traefik image
    if docker images -q "traefik" 2>/dev/null | grep -q .; then
        echo "Removing traefik image..."
        docker rmi traefik:v3 2>/dev/null || true
    fi

    # Remove devproxy network
    if docker network inspect devproxy >/dev/null 2>&1; then
        echo "Removing devproxy network..."
        docker network rm devproxy 2>/dev/null || true
    fi

    # Remove symlink
    if [ -L "/usr/local/bin/devbox" ]; then
        echo "Removing /usr/local/bin/devbox symlink..."
        sudo rm -f /usr/local/bin/devbox
    fi

    # Remove install directory (if installed via install.sh)
    INSTALL_DIR="$HOME/.local/share/devbox"
    if [ -d "$INSTALL_DIR" ]; then
        echo "Removing install directory: $INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
    fi

    # Ask about config directory
    CONFIG_DIR="$HOME/.config/devbox"
    # Also check old location
    [ -d "$HOME/.devbox" ] && [ ! -d "$CONFIG_DIR" ] && CONFIG_DIR="$HOME/.devbox"
    if [ -d "$CONFIG_DIR" ]; then
        echo ""
        echo "Config directory found: $CONFIG_DIR"
        echo "  Contains: allowed-domains.conf, default-ports.conf, traefik configs"
        if [ -t 0 ]; then
            printf "Remove config directory? [y/N] "
            read -r answer
            if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
                rm -rf "$CONFIG_DIR"
                echo "Removed: $CONFIG_DIR"
            else
                echo "Kept: $CONFIG_DIR"
            fi
        else
            echo "  Skipped (non-interactive). Remove manually: rm -rf $CONFIG_DIR"
        fi
    fi

    echo ""
    echo "=== Uninstall done ==="
    exit 0
fi

# --- Sudo password prompt ---------------------------------------------------
# Password is set at build time so sudo inside the container requires authentication.
# This prevents AI agents / untrusted code from modifying firewall rules via sudo.
# Passed via --mount=type=secret to avoid leaking into image layers/metadata.
SUDO_PASSWORD_FILE=$(mktemp)
trap 'rm -f "$SUDO_PASSWORD_FILE"' EXIT
if [ -t 0 ]; then
    read -s -r -p "Set sudo password for devbox: " SUDO_PASSWORD
    echo ""
    read -s -r -p "Confirm password: " SUDO_PASSWORD_CONFIRM
    echo ""
    if [ "$SUDO_PASSWORD" != "$SUDO_PASSWORD_CONFIRM" ]; then
        echo "ERROR: Passwords don't match"
        exit 1
    fi
    if [ -z "$SUDO_PASSWORD" ]; then
        echo "ERROR: Password cannot be empty"
        exit 1
    fi
else
    # Non-interactive: use env var or default
    SUDO_PASSWORD="${DEVBOX_SUDO_PASSWORD:-devbox}"
fi
printf '%s' "$SUDO_PASSWORD" > "$SUDO_PASSWORD_FILE"
unset SUDO_PASSWORD SUDO_PASSWORD_CONFIRM
DOCKER_ARGS+=(--secret "id=sudo_password,src=$SUDO_PASSWORD_FILE")
# Force cache invalidation — secret content alone doesn't bust Docker build cache
DOCKER_ARGS+=(--build-arg "SUDO_CACHE_BUST=$(date +%s)")

if [ "$CLEAN" = true ]; then
    echo "=== Clean: full reset ==="
    full_reset
fi

# Capture old image ID before build (for dangling cleanup)
OLD_IMAGE_ID=$(docker images -q "$IMAGE" 2>/dev/null || true)

echo "=== Building $IMAGE ==="
docker build -t "$IMAGE" "${DOCKER_ARGS[@]}" "$(dirname "$0")"

NEW_IMAGE_ID=$(docker images -q "$IMAGE" 2>/dev/null || true)

echo ""
echo "=== Cleanup ==="

# Remove old devbox image if it became dangling (replaced by new build)
if [ -n "$OLD_IMAGE_ID" ] && [ "$OLD_IMAGE_ID" != "$NEW_IMAGE_ID" ]; then
    echo "Removing old devbox image ($OLD_IMAGE_ID)..."
    docker rmi "$OLD_IMAGE_ID" 2>/dev/null || true
fi

# Remove any remaining dangling images from devbox builds
DANGLING=$(docker images -q --filter "dangling=true" 2>/dev/null || true)
if [ -n "$DANGLING" ]; then
    echo "Removing dangling images..."
    # shellcheck disable=SC2086  # intentional word splitting — each image ID is a separate arg
    docker rmi $DANGLING 2>/dev/null || true
fi


echo ""
echo "=== Done ==="
docker images "$IMAGE" --format "Image: {{.Repository}}:{{.Tag}}  Size: {{.Size}}  Created: {{.CreatedSince}}"
echo ""
echo "Build cache usage:"
docker system df --format '{{.Type}}\t{{.Size}} total, {{.Reclaimable}} reclaimable' 2>/dev/null | grep -i "build" || true
echo ""
echo "Tip: run 'devbox build --clean' for full reset (volumes + cache) + rebuild"
echo "      run 'devbox uninstall' for full removal"
