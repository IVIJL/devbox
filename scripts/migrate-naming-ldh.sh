#!/bin/bash
set -euo pipefail
# One-shot migration: rename devbox containers and per-project volumes whose
# names contain characters the (newly tightened) `devbox::sanitize` would now
# replace with `-`. Triggered automatically by `devbox update` for the LDH
# break-fix where pre-fix names produced a Traefik route that violated
# RFC 1034/1035 (e.g. `8000.foo_bar.127.0.0.1.traefik.me` → DisallowedHost).
#
# Strategy:
#   - volumes:    data-copy via alpine `cp -a` into a freshly-created LDH
#                 volume. Refuses to migrate when the LDH target already
#                 exists — distinct legacy basenames can sanitize to the
#                 same LDH name (e.g. `foo_bar` and `foo.bar` both → `foo-bar`)
#                 and silent merge would mix unrelated projects' data.
#   - containers: stop + rm. Container hostname is immutable post-`docker run`,
#                 so a rename would leave the old hostname inside. Persistent
#                 data lives in volumes (now migrated); overlay state is
#                 ephemeral by ADR 0002. The next `devbox <project>` recreates
#                 the container fresh against the renamed volumes.
#   - traefik:    delete dynamic config files keyed by the old container name;
#                 they regenerate on next start.
#
# See ADR 0005 (sanitize end-to-end) and its 2026-05-06 amendment.

CYAN='\033[1;36m'; YELLOW='\033[1;33m'; GREEN='\033[1;32m'; RED='\033[1;31m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=../lib/naming.sh disable=SC1091
source "$SCRIPT_DIR/../lib/naming.sh"

TRAEFIK_CONFIG_DIR="$HOME/.config/devbox/traefik/dynamic"

AUTO=false
CHECK_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --auto) AUTO=true ;;
        --check) CHECK_ONLY=true ;;
    esac
done

# Discover raw project names that need migration. A project needs migration
# if any of its devbox- objects (container or per-project volume) carries
# chars that LDH-sanitize would now change.
discover_projects() {
    local seen=()

    # Containers: name = devbox-<raw>
    while IFS= read -r c; do
        [ -z "$c" ] && continue
        local raw="${c#devbox-}"
        [ "$raw" = "$c" ] && continue          # safety: prefix didn't strip
        [ "$raw" = "traefik" ] && continue     # devbox-traefik is shared infra
        local sanitized
        sanitized="$(devbox::sanitize "$raw")"
        [ "$raw" = "$sanitized" ] && continue
        seen+=("$raw")
    done < <(docker ps -a --filter "name=^devbox-" --format '{{.Names}}' 2>/dev/null || true)

    # Volumes: name = devbox-<raw>-(history|docker)
    local vol_regex
    vol_regex="$(devbox::project_volume_regex)"
    while IFS= read -r v; do
        [ -z "$v" ] && continue
        [[ "$v" =~ $vol_regex ]] || continue
        # strip prefix and known suffix to recover raw
        local raw="${v#devbox-}"
        local suffix
        for suffix in "${DEVBOX_PROJECT_VOLUME_SUFFIXES[@]}"; do
            if [[ "$raw" == *-"$suffix" ]]; then
                raw="${raw%-"$suffix"}"
                break
            fi
        done
        local sanitized
        sanitized="$(devbox::sanitize "$raw")"
        [ "$raw" = "$sanitized" ] && continue
        seen+=("$raw")
    done < <(docker volume ls --format '{{.Name}}' 2>/dev/null || true)

    printf '%s\n' "${seen[@]+"${seen[@]}"}" | sort -u
}

mapfile -t projects < <(discover_projects)

if [ ${#projects[@]} -eq 0 ]; then
    [ "$CHECK_ONLY" = true ] && exit 1
    echo -e "${GREEN}No legacy (non-LDH) devbox names found. Nothing to migrate.${NC}"
    exit 0
fi

if [ "$CHECK_ONLY" = true ]; then
    exit 0
fi

echo -e "${CYAN}=== Devbox naming migration: tighten to RFC 1034/1035 LDH ===${NC}"
echo "Found ${#projects[@]} project(s) with non-LDH names:"
for raw in "${projects[@]}"; do
    sanitized="$(devbox::sanitize "$raw")"
    echo "  - $raw  →  $sanitized"
done
echo
echo "Per project:"
echo "  - Stop the running container (if any)"
echo "  - Copy each ${DEVBOX_PROJECT_VOLUME_SUFFIXES[*]} volume to its LDH name (data preserved)"
echo "  - Remove the old volumes and old container"
echo "  - Drop stale traefik dynamic configs (regenerated on next start)"
echo

if [ "$AUTO" = true ]; then
    echo "(auto mode: proceeding without prompt)"
else
    read -rp "Proceed? [y/N] " ans || ans=""
    [[ "$ans" =~ ^[Yy] ]] || { echo "Aborted."; exit 1; }
fi

# Migrate one volume from legacy name to LDH name. Refuses to merge if the
# target already exists: two distinct legacy basenames can sanitize to the
# same LDH name (e.g. `foo_bar` and `foo.bar` both → `foo-bar`), and a silent
# merge under `devbox update --auto` would mix unrelated projects' data.
# User resolves manually: inspect both, then `docker volume rm <stale>` and
# re-run.
#
# Returns non-zero on collision OR on copy failure. Caller treats either as
# a project failure: container + traefik cleanup is skipped so the legacy
# resources stay coherent until the user fixes the issue.
migrate_volume() {
    local src="$1" dst="$2"
    if docker volume inspect "$dst" >/dev/null 2>&1; then
        echo -e "    ${RED}Target volume '$dst' already exists.${NC}" >&2
        echo "      Refusing to merge — could belong to an unrelated project that" >&2
        echo "      sanitizes to the same LDH name. Inspect both volumes, then" >&2
        echo "      'docker volume rm <stale>' and re-run 'devbox migrate-naming'." >&2
        return 1
    fi
    docker volume create "$dst" >/dev/null
    if ! docker run --rm \
        -v "$src:/from:ro" \
        -v "$dst:/to" \
        alpine cp -a /from/. /to/; then
        echo -e "    ${RED}Copy failed; removing partial target '$dst' and leaving '$src' intact.${NC}" >&2
        docker volume rm "$dst" >/dev/null 2>&1 || true
        return 1
    fi
}

failures=0
for raw in "${projects[@]}"; do
    sanitized="$(devbox::sanitize "$raw")"
    echo
    echo -e "${CYAN}== $raw → $sanitized ==${NC}"

    project_failed=false
    old_container="devbox-${raw}"
    if docker ps --filter "name=^${old_container}$" --format '{{.ID}}' | grep -q .; then
        echo "  Stopping $old_container..."
        docker stop -t 30 "$old_container" >/dev/null
    fi

    for suffix in "${DEVBOX_PROJECT_VOLUME_SUFFIXES[@]}"; do
        old_vol="devbox-${raw}-${suffix}"
        new_vol="devbox-${sanitized}-${suffix}"
        if docker volume inspect "$old_vol" >/dev/null 2>&1; then
            echo "  Volume $old_vol → $new_vol"
            if ! migrate_volume "$old_vol" "$new_vol"; then
                project_failed=true
                failures=$((failures + 1))
                continue
            fi
            docker volume rm "$old_vol" >/dev/null
        fi
    done

    # If any volume migration failed, don't tear down container or traefik
    # configs — the legacy resources stay self-consistent so the user can
    # diagnose, fix, and re-run safely.
    if [ "$project_failed" = true ]; then
        echo -e "  ${YELLOW}Skipping container/traefik cleanup for '$raw' — fix volume issue and re-run.${NC}" >&2
        continue
    fi

    if docker ps -a --filter "name=^${old_container}$" --format '{{.ID}}' | grep -q .; then
        echo "  Removing container $old_container"
        docker rm "$old_container" >/dev/null
    fi

    if [ -d "$TRAEFIK_CONFIG_DIR" ]; then
        # Match the layout written by apply_port_routes:
        #   ${TRAEFIK_CONFIG_DIR}/${container}-${port}.yml
        shopt -s nullglob
        stale_cfgs=("$TRAEFIK_CONFIG_DIR/${old_container}-"*.yml)
        shopt -u nullglob
        if [ ${#stale_cfgs[@]} -gt 0 ]; then
            rm -f -- "${stale_cfgs[@]}"
            echo "  Removed ${#stale_cfgs[@]} stale traefik config(s)"
        fi
    fi
done

echo
if [ "$failures" -gt 0 ]; then
    echo -e "${RED}Migration finished with $failures failure(s).${NC}" >&2
    exit 1
fi
echo -e "${GREEN}Naming migration done.${NC} Next \`devbox <project>\` recreates containers with LDH names + hostnames."
