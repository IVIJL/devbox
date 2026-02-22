#!/bin/bash
set -euo pipefail

# =============================================================================
# Devbox - Build script with automatic cleanup
# =============================================================================
# Usage:
#   ./build.sh                    # normal build (uses cache)
#   ./build.sh --no-cache         # full rebuild without cache
#   ./build.sh --progress=plain   # show full build log
#   ./build.sh --clean-cache      # prune build cache after build
#
# All arguments are passed through to docker build (except --clean-cache).
# =============================================================================

CLEAN_CACHE=false
DOCKER_ARGS=()
for arg in "$@"; do
    if [ "$arg" = "--clean-cache" ]; then
        CLEAN_CACHE=true
    else
        DOCKER_ARGS+=("$arg")
    fi
done

IMAGE="vlcak/devbox:latest"

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

# Prune build cache only when explicitly requested
if [ "$CLEAN_CACHE" = true ]; then
    echo "Pruning build cache..."
    docker builder prune -f 2>/dev/null || true
fi

echo ""
echo "=== Done ==="
docker images "$IMAGE" --format "Image: {{.Repository}}:{{.Tag}}  Size: {{.Size}}  Created: {{.CreatedSince}}"
echo ""
echo "Build cache usage:"
docker system df --format '{{.Type}}\t{{.Size}} total, {{.Reclaimable}} reclaimable' 2>/dev/null | grep -i "build" || true
echo ""
echo "Tip: run './build.sh --clean-cache' to prune build cache"
