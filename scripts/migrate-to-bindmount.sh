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
TRANSLATE_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --auto) AUTO=true ;;
        --translate-keys) TRANSLATE_ONLY=true ;;
    esac
done

# Rewrite the top-level .cwd JSON field in every *.jsonl in $dir from $from to
# $to. Only the structural .cwd field — string occurrences inside text content
# (tool inputs, transcripts) are preserved by going through jq, not sed.
#
# After rewrite, restore mtime to the latest "timestamp" entry inside the
# jsonl. /resume sorts by file mtime, and `jq > tmp && mv` would otherwise
# stamp every touched session with the migration moment, collapsing them all
# to "X minutes ago" in the picker.
rewrite_cwd_in_jsonl() {
    local dir="$1" from="$2" to="$3" f max_ts count=0
    if ! command -v jq >/dev/null 2>&1; then
        echo -e "  ${YELLOW}Warning: jq not found, skipping .cwd rewrite in $(basename "$dir")${NC}"
        return 0
    fi
    shopt -s nullglob
    for f in "$dir"/*.jsonl; do
        # Cheap pre-filter avoids rewriting files that don't contain the stale value.
        if grep -q "\"cwd\":\"$from\"" "$f"; then
            jq -c --arg from "$from" --arg to "$to" \
                'if .cwd == $from then .cwd = $to else . end' "$f" > "$f.tmp" \
                && mv "$f.tmp" "$f"
            max_ts=$(grep -oE '"timestamp":"[^"]+"' "$f" | sed 's/"timestamp":"//;s/"$//' | sort -u | tail -1)
            [ -n "$max_ts" ] && touch -d "$max_ts" "$f"
            count=$((count + 1))
        fi
    done
    shopt -u nullglob
    if [ "$count" -gt 0 ]; then
        echo "  Rewrote .cwd in $count jsonl file(s) under $(basename "$dir")"
    fi
}

# Translate /workspace-keyed session/project subdirs in ~/.claude to host-path
# encoding so /resume picks them up under Phase 2's host-path CWD. Two passes:
#   A) -workspace-<name> dirs that were never renamed → rename + rewrite .cwd
#   B) already-renamed dirs whose jsonl still holds /workspace/<name> .cwd
#      (heal pass for installs that ran an older translate-keys that only
#      renamed the dir without touching contents)
# Idempotent and opt-in: skipping a project leaves its data as-is.
translate_workspace_keys() {
    echo
    echo -e "${CYAN}=== Phase 2: session/project key translation ===${NC}"
    echo "Container CWD changed from /workspace/<project> to your host project path."
    echo "Old subdirs keyed by /workspace/* and stale .cwd inside jsonl would be invisible to /resume."
    echo

    mapfile -t old_keys < <(find "$HOME/.claude/sessions" "$HOME/.claude/projects" \
        -mindepth 1 -maxdepth 1 -type d -name '-workspace-*' 2>/dev/null | sort -u)

    mapfile -t stale_dirs < <(
        find "$HOME/.claude/sessions" "$HOME/.claude/projects" \
            -mindepth 1 -maxdepth 1 -type d ! -name '-workspace*' ! -name '.*' 2>/dev/null \
        | while IFS= read -r d; do
            if grep -lq '"cwd":"/workspace/' "$d"/*.jsonl 2>/dev/null; then
                printf '%s\n' "$d"
            fi
        done | sort -u
    )

    if [ ${#old_keys[@]} -eq 0 ] && [ ${#stale_dirs[@]} -eq 0 ]; then
        echo "Nothing to translate. Done."
        return 0
    fi

    if [ ${#old_keys[@]} -gt 0 ]; then
        echo "Old /workspace-keyed dirs (will rename + rewrite .cwd):"
        printf '  %s\n' "${old_keys[@]}"
    fi
    if [ ${#stale_dirs[@]} -gt 0 ]; then
        echo "Renamed dirs with stale .cwd inside jsonl (will rewrite .cwd):"
        printf '  %s\n' "${stale_dirs[@]}"
    fi
    echo

    if [ "$AUTO" = true ]; then
        echo "(auto mode: skipping translation — run 'devbox migrate --translate-keys' to do it interactively)"
        return 0
    fi
    # `|| ans=""` so EOF on stdin (closed pipe, Ctrl-D) cleanly skips instead
    # of tripping `set -e`. Same pattern on every read in this function.
    read -rp "Translate now? [y/N] " ans || ans=""
    if ! [[ "$ans" =~ ^[Yy] ]]; then
        echo "Skipped. Old data left as-is."
        return 0
    fi

    # One root prompt up front: most people keep all projects under one parent
    # (~/Projekty, ~/src, ~/work). When set, <root>/<name> is auto-resolved
    # without a per-project prompt; only unmatched names fall through to ask.
    echo
    read -rp "Common project root (e.g. /home/vlcak/Projekty), empty to prompt per project: " projects_root || projects_root=""
    projects_root="${projects_root%/}"

    # Collect every project NAME we need to resolve, from both passes.
    declare -A name_seen
    for dir in "${old_keys[@]}"; do
        n=$(basename "$dir" | sed 's/^-workspace-//')
        name_seen[$n]=1
    done
    for dir in "${stale_dirs[@]}"; do
        while IFS= read -r n; do
            [ -n "$n" ] && name_seen[$n]=1
        done < <(grep -oh '"cwd":"/workspace/[^"]*"' "$dir"/*.jsonl 2>/dev/null \
            | sed 's|"cwd":"/workspace/||;s|"$||' | sort -u)
    done

    # Resolve each name to its host path: auto under root, else prompt.
    declare -A name_to_path
    for name in "${!name_seen[@]}"; do
        if [ -n "$projects_root" ] && [ -d "$projects_root/$name" ]; then
            name_to_path[$name]="$projects_root/$name"
            echo "  '$name' → $projects_root/$name (auto-detected under root)"
            continue
        fi
        echo
        read -rp "Host path for project '$name' (empty to skip): " hostpath || hostpath=""
        if [ -z "$hostpath" ]; then
            name_to_path[$name]="SKIP"
            continue
        fi
        if [ ! -d "$hostpath" ]; then
            echo "  Path doesn't exist, skipping '$name'."
            name_to_path[$name]="SKIP"
            continue
        fi
        name_to_path[$name]="$hostpath"
    done

    # Pass A: rename/merge -workspace-<name> dirs and rewrite .cwd inside.
    for dir in "${old_keys[@]}"; do
        name=$(basename "$dir" | sed 's/^-workspace-//')
        hostpath="${name_to_path[$name]:-SKIP}"
        [ "$hostpath" = "SKIP" ] && continue

        # Encode host path: /home/vlcak/Projekty/devbox → -home-vlcak-Projekty-devbox
        new_key="-${hostpath#/}"
        new_key="${new_key//\//-}"
        parent=$(dirname "$dir")
        new_dir="$parent/$new_key"

        if [ -e "$new_dir" ]; then
            rsync -a --ignore-existing "$dir/" "$new_dir/"
            rm -rf "$dir"
            echo "Merged $dir -> $new_dir"
        else
            mv "$dir" "$new_dir"
            echo "Renamed $dir -> $new_dir"
        fi

        rewrite_cwd_in_jsonl "$new_dir" "/workspace/$name" "$hostpath"
    done

    # Pass B: heal already-renamed dirs by rewriting stale .cwd fields inside.
    for dir in "${stale_dirs[@]}"; do
        mapfile -t stale_names < <(grep -oh '"cwd":"/workspace/[^"]*"' "$dir"/*.jsonl 2>/dev/null \
            | sed 's|"cwd":"/workspace/||;s|"$||' | sort -u)
        for name in "${stale_names[@]}"; do
            hostpath="${name_to_path[$name]:-SKIP}"
            [ "$hostpath" = "SKIP" ] && continue
            rewrite_cwd_in_jsonl "$dir" "/workspace/$name" "$hostpath"
        done
    done

    echo -e "${GREEN}Translation complete.${NC}"
}

# `devbox migrate --translate-keys` runs only the translation step.
if [ "$TRANSLATE_ONLY" = true ]; then
    translate_workspace_keys
    exit 0
fi

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
    translate_workspace_keys
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

# 8. (Phase 2) Optionally translate /workspace-keyed session/project subdirs.
translate_workspace_keys

echo
echo -e "${GREEN}Migration done.${NC} Next steps:"
echo "  devbox build    # rebuild image with new layout"
echo "  devbox          # start container with bind-mounted ~/.claude"
