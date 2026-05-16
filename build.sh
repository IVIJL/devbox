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
  ./build.sh --clean               Wipe build cache + dangling images, then rebuild
  ./build.sh --uninstall           Full reset without rebuild
  ./build.sh --uninstall --purge-ca
                                   Full reset AND remove mkcert root CA from
                                   system trust stores (WSL2 fires one UAC).

All other flags pass through to docker build.
Set DEVBOX_SUDO_PASSWORD env var for non-interactive builds.
To reclaim build cache space without rebuilding, use: devbox prune
EOF
    exit 0
}

case "${1:-}" in
    -h|--help) show_help ;;
esac

CLEAN=false
UNINSTALL=false
# 'auto' = prompt interactively (default n) or skip in non-interactive.
# 'yes'  = --purge-ca explicit; no prompt, fire UAC / sudo.
PURGE_CA=auto
DOCKER_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --clean)     CLEAN=true ;;
        --uninstall) UNINSTALL=true ;;
        --purge-ca)  PURGE_CA=yes ;;
        *)           DOCKER_ARGS+=("$arg") ;;
    esac
done

IMAGE="vlcak/devbox:latest"

# Devbox-managed container name pattern — both the dash-prefix user
# projects (`devbox-<project>`) and the two explicit underscore shared-infra
# names (`devbox_traefik`, `devbox_dns`, introduced by ADR 0007). The
# dash-prefix half can stay broad because `devbox::sanitize` is the only
# producer of those names; the underscore half must list the two infra
# names exactly so a hand-created Docker container that happens to start
# with `devbox_` (e.g. a personal `devbox_postgres`) is not caught and
# torn down. Keep this in sync with `DEVBOX_SHARED_CONTAINER_NAMES` in
# docker-run.sh.
DEVBOX_CONTAINER_PATTERN='^devbox-|^devbox_traefik$|^devbox_dns$'

# Prune build cache + dangling images. Does NOT touch running containers
# or volumes — the user keeps their work and existing per-project state
# across rebuilds.
prune_build_artifacts() {
    echo "Pruning all build cache..."
    docker builder prune --all -f 2>/dev/null || true

    echo "Pruning dangling images..."
    docker image prune -f 2>/dev/null || true

    echo ""
}

# Stop and remove every devbox-managed container. Only used by the
# uninstall path; `--clean` deliberately does not call this.
remove_all_devbox_containers() {
    CONTAINERS=$(docker ps -a --format '{{.Names}}' 2>/dev/null \
        | grep -E "$DEVBOX_CONTAINER_PATTERN" || true)
    if [ -n "$CONTAINERS" ]; then
        echo "Stopping devbox containers..."
        while IFS= read -r c; do
            docker stop -t 15 "$c" > /dev/null 2>&1 || true
            docker rm "$c" > /dev/null 2>&1 || true
            echo "  Removed: $c"
        done <<< "$CONTAINERS"
    fi
}

# Wipe all devbox-* volumes. Destructive: kills per-project shell history,
# DinD storage, and shared caches (devbox-npm-global, etc.). Only used by
# the uninstall path; `--clean` deliberately does not call this.
remove_all_devbox_volumes() {
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
}

# --- Uninstall: full reset without rebuild -----------------------------------

if [ "$UNINSTALL" = true ]; then
    echo "=== Uninstall: full reset ==="

    # Tear down the host-side DNS resolver wiring first. It lives outside
    # Docker (per-OS resolver drop-ins, Windows NRPT, ~/.config/devbox/dns.conf)
    # so the container / volume / image cleanup below wouldn't touch any of it.
    # May prompt for sudo and on WSL2 may pop a UAC dialog for the NRPT
    # rule — same expectations as `devbox dns-install`. `|| true` so a
    # UAC decline (or any partial failure) doesn't abort the rest of the
    # uninstall flow; users can re-run `devbox dns-uninstall` standalone.
    SCRIPT_PARENT="$(cd "$(dirname "$0")" && pwd)"
    if [ -x "$SCRIPT_PARENT/scripts/dns-install.sh" ]; then
        echo ""
        echo "Removing host DNS resolver configuration..."
        "$SCRIPT_PARENT/scripts/dns-install.sh" uninstall || true
    fi

    # CA purge is opt-in: mkcert is sometimes shared with non-devbox projects,
    # so we never strip the root CA from the user's trust stores without an
    # explicit signal. The trust-store removal fires a UAC prompt on WSL2 +
    # a sudo / Touch ID prompt on Linux / macOS, which is also why we keep
    # it strictly behind interactive confirmation when --purge-ca was not
    # passed: a surprise UAC popup during `devbox uninstall` would feel
    # broken even though it is correct cleanup.
    should_purge_ca=false
    case "$PURGE_CA" in
        yes)
            should_purge_ca=true
            ;;
        auto)
            # Only offer when there is something to purge — a missing
            # https.conf means the user never enabled HTTPS on this host,
            # so the question would be confusing.
            if [ -f "$HOME/.config/devbox/https.conf" ]; then
                if [ -t 0 ]; then
                    echo ""
                    echo "Remove mkcert root CA from system trust stores?"
                    echo "  This affects ALL mkcert-issued certs on this host, not just devbox."
                    echo "  Fires a UAC prompt on WSL2 (Windows side) or sudo / Touch ID on Linux / macOS."
                    printf "Purge CA? [y/N] "
                    read -r answer
                    case "$answer" in
                        y|Y) should_purge_ca=true ;;
                    esac
                else
                    echo ""
                    echo "Skipped CA purge (non-interactive). Re-run with --purge-ca to remove the mkcert root CA."
                fi
            fi
            ;;
    esac

    if [ "$should_purge_ca" = true ] \
        && [ -x "$SCRIPT_PARENT/scripts/dns-install.sh" ]; then
        echo ""
        echo "Purging mkcert root CA from trust stores..."
        "$SCRIPT_PARENT/scripts/dns-install.sh" purge-ca || true
    fi

    remove_all_devbox_containers
    remove_all_devbox_volumes
    prune_build_artifacts

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
    echo "=== Clean: prune build cache + dangling images ==="
    prune_build_artifacts
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

# Heads-up about containers running the OLD image. Each one keeps its
# pinned image ID until stopped & restarted, so the rebuild does not
# affect them automatically. We deliberately do not stop them here.
RUNNING=$(docker ps --format '{{.Names}}' 2>/dev/null \
    | grep -E "$DEVBOX_CONTAINER_PATTERN" || true)
if [ -n "$RUNNING" ]; then
    echo ""
    echo "Note: the following devbox containers are still running the previous image."
    echo "      Stop and restart them to pick up the new build:"
    while IFS= read -r c; do
        echo "  - $c"
    done <<< "$RUNNING"
fi

echo ""
echo "Tip: run 'devbox build --clean' to wipe build cache + dangling images and rebuild"
echo "      run 'devbox uninstall' for full removal"
