#!/bin/bash
set -euo pipefail
# One-shot migration: merge per-container devbox-claude volume contents into
# host ~/.claude, then remove obsolete volumes. Run once before rebuilding
# devbox image with the new bind-mount architecture.
#
# Volume detection covers both layouts: the unified `devbox-claude` (introduced
# in d364a16) and per-project `devbox-<name>-claude` from the earlier layout.

CYAN='\033[1;36m'; YELLOW='\033[1;33m'; GREEN='\033[1;32m'; RED='\033[1;31m'; NC='\033[0m'

AUTO=false
[ "${1:-}" = "--auto" ] && AUTO=true

echo -e "${CYAN}=== Devbox migration: per-container volume(s) → host bind mount ===${NC}"
echo "Backs up nothing — this is a merge into your existing ~/.claude/."
echo "Host files win for non-credentials (settings.json, hooks, etc.)."
echo ".credentials.json uses newer-mtime-wins so a refreshed token in the"
echo "  volume isn't lost (the bug this migration is fixing — see ADR 0002)."
echo

# 0. Idempotent cleanup of pre-bind-mount symlink-dance leftovers. Older
# setup-claude.sh symlinked ~/.claude/.credentials.lock into the now-removed
# ~/.claude-host sidecar; the dangling symlink survives in the bind-mounted
# dir and breaks Claude's OAuth refresh flock. Runs every invocation so
# instances coming up after their peers also get healed.
if [ -L "$HOME/.claude/.credentials.lock" ] && [ ! -e "$HOME/.claude/.credentials.lock" ]; then
    rm -f "$HOME/.claude/.credentials.lock"
    echo "Removed stale ~/.claude/.credentials.lock (dangling symlink into retired sidecar)"
fi

# 1. Stop all running devbox containers (skips traefik) so volumes can be read.
running=$(docker ps --filter "name=^devbox-" --filter "status=running" --format '{{.Names}}' | grep -v '^devbox-traefik$' || true)
if [ -n "$running" ]; then
    echo -e "${YELLOW}Stopping running containers...${NC}"
    echo "$running" | xargs -r docker stop -t 30
    echo
fi

# 2. Discover all pre-migration Claude volumes.
mapfile -t volumes < <(docker volume ls --format '{{.Name}}' | grep -E '^devbox-(.+-)?claude$' || true)

if [ ${#volumes[@]} -eq 0 ]; then
    echo -e "${GREEN}No pre-migration Claude volumes found. Nothing to merge.${NC}"
    for vol in devbox-claude-bin devbox-codex-bin; do
        if docker volume inspect "$vol" >/dev/null 2>&1; then
            docker volume rm "$vol" >/dev/null 2>&1 && echo "Removed obsolete: $vol"
        fi
    done
    exit 0
fi

# 3. Pre-migration safety: ensure host ~/.claude exists and is writable.
mkdir -p "$HOME/.claude"
[ -w "$HOME/.claude" ] || { echo -e "${RED}~/.claude not writable, aborting${NC}"; exit 1; }

# 4. Show what will be merged.
echo "Pre-migration volumes detected:"
for vol in "${volumes[@]}"; do
    echo "  - $vol"
    docker run --rm -v "$vol:/from:ro" alpine sh -c 'ls /from 2>/dev/null' | sed 's/^/      /'
done
echo
echo "Merge strategy:"
echo "  - Settings, hooks, sessions, etc.: rsync --ignore-existing (host wins)"
echo "  - .credentials.json:               rsync -u (newer mtime wins)"
if [ "$AUTO" = true ]; then
    echo "(auto mode: proceeding without prompt)"
    ans=y
else
    read -rp "Proceed? [y/N] " ans
fi
[[ "$ans" =~ ^[Yy] ]] || { echo "Aborted."; exit 1; }

# 5. Merge each volume into host ~/.claude. Two-pass rsync per volume:
#    Pass 1: --ignore-existing --exclude='.credentials.json' — host config wins
#    Pass 2: -u on .credentials.json only — newer file wins (handles the
#            atomic-rename divergence the new layout is fixing)
host_uid=$(id -u)
host_gid=$(id -g)
for vol in "${volumes[@]}"; do
    echo
    echo -e "${CYAN}Merging $vol → ~/.claude/${NC}"
    docker run --rm \
        -v "$vol:/from:ro" \
        -v "$HOME/.claude:/to" \
        -e UID="$host_uid" -e GID="$host_gid" \
        alpine sh -c '
            apk add --no-cache rsync >/dev/null 2>&1
            rsync -a --ignore-existing --exclude=".credentials.json" --info=name1 /from/ /to/
            if [ -f /from/.credentials.json ]; then
                rsync -au --info=name1 /from/.credentials.json /to/.credentials.json
            fi
            chown -R "$UID:$GID" /to/
        '
done
echo -e "${GREEN}Merge complete.${NC}"

# 6. Confirm before removing volumes.
echo
if [ "$AUTO" = true ]; then
    ans=y
else
    read -rp "Remove migrated volume(s) now (${volumes[*]})? [y/N] " ans
fi
if [[ "$ans" =~ ^[Yy] ]]; then
    for vol in "${volumes[@]}"; do
        docker volume rm "$vol" >/dev/null 2>&1 && echo "Removed: $vol"
    done
fi

# 7. Cleanup other obsolete volumes.
for vol in devbox-claude-bin devbox-codex-bin; do
    if docker volume inspect "$vol" >/dev/null 2>&1; then
        docker volume rm "$vol" >/dev/null 2>&1 && echo "Removed obsolete: $vol"
    fi
done

echo
echo -e "${GREEN}Migration done.${NC} Next steps:"
echo "  devbox build    # rebuild image with new layout"
echo "  devbox          # start container with bind-mounted ~/.claude"
