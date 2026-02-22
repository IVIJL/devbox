#!/bin/bash
set -euo pipefail

# =============================================================================
# Devbox - Build script with automatic cleanup
# =============================================================================
# Usage:
#   ./build.sh                    # normal build (uses cache)
#   ./build.sh --no-cache         # full rebuild without cache
#   ./build.sh --progress=plain   # show full build log
#   ./build.sh --clean            # full reset: remove volumes + cache + images, then build
#
# All arguments are passed through to docker build (except --clean).
# =============================================================================

CLEAN=false
DOCKER_ARGS=()
for arg in "$@"; do
    if [ "$arg" = "--clean" ]; then
        CLEAN=true
    else
        DOCKER_ARGS+=("$arg")
    fi
done

IMAGE="vlcak/devbox:latest"

# Full reset before build: volumes, cache, dangling images
if [ "$CLEAN" = true ]; then
    echo "=== Clean: full reset ==="

    VOLUMES=$(docker volume ls -q --filter "name=devbox-" 2>/dev/null || true)
    if [ -n "$VOLUMES" ]; then
        echo "Removing devbox volumes:"
        echo "$VOLUMES"
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
    docker rmi $DANGLING 2>/dev/null || true
fi


echo ""
echo "=== Done ==="
docker images "$IMAGE" --format "Image: {{.Repository}}:{{.Tag}}  Size: {{.Size}}  Created: {{.CreatedSince}}"
echo ""
echo "Build cache usage:"
docker system df --format '{{.Type}}\t{{.Size}} total, {{.Reclaimable}} reclaimable' 2>/dev/null | grep -i "build" || true
echo ""
echo "Tip: run './build.sh --clean' for full reset (volumes + cache + images)"
echo "Manual cleanup:"
echo "  docker volume ls --filter \"name=devbox-\"                              # list devbox volumes"
echo "  docker volume rm \$(docker volume ls -q --filter \"name=devbox-\")       # remove all"
echo "  docker builder prune -f                                               # clear build cache"
echo "  docker system prune -a                                                # remove everything unused"
