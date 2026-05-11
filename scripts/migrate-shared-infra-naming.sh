#!/bin/bash
set -euo pipefail
# One-shot migration: rename shared devbox infrastructure containers from
# dash-separator to underscore-separator.
#
#   devbox-traefik → devbox_traefik
#   devbox-dns     → devbox_dns
#
# Triggered automatically by `devbox update`.
#
# Why: user project names sanitize to `devbox-<token>`, which collided with
# `devbox-traefik` (project named "traefik") and `devbox-dns` (project named
# "dns"). The underscore separator is impossible for `devbox::sanitize` to
# produce, so the user-project namespace and the shared-infra namespace are
# now provably disjoint.
#
# Strategy: stop + remove legacy containers. Both pieces of shared infra
# have no per-container persistent state — Traefik dynamic config and the
# dnsmasq config both live under ~/.config/devbox/ and are bind-mounted on
# every start. Next `devbox <project>` invocation recreates the shared
# infra under the new names.
#
# Network: the `devproxy` network identifies members by container ID. The
# freshly created devbox_traefik / devbox_dns join the same network on
# next bootstrap; running user devbox containers continue to be reachable
# through the existing network without restart.
#
# See ADR 0007 § "Refactor of lib/naming.sh" and the underscore-separator
# rationale in docker-run.sh § DEVBOX_SHARED_CONTAINER_NAMES.

CYAN='\033[1;36m'; GREEN='\033[1;32m'; RED='\033[1;31m'; NC='\033[0m'

# Legacy → new mapping.
declare -A SHARED_RENAMES=(
    [devbox-traefik]=devbox_traefik
    [devbox-dns]=devbox_dns
)

usage() {
    cat <<USAGE
Usage: migrate-shared-infra-naming.sh [--check | --auto | --help]

  --check    Exit 0 iff at least one legacy shared-infra container exists.
             Used by \`devbox update\` to decide whether to auto-migrate.
  --auto     Run the migration non-interactively (default if no flag given).
  --help     Show this message.
USAGE
}

legacy_exists() {
    local legacy
    for legacy in "${!SHARED_RENAMES[@]}"; do
        if docker ps -a --filter "name=^${legacy}$" --format '{{.ID}}' | grep -q .; then
            return 0
        fi
    done
    return 1
}

migrate() {
    local migrated=0 legacy new
    for legacy in "${!SHARED_RENAMES[@]}"; do
        if ! docker ps -a --filter "name=^${legacy}$" --format '{{.ID}}' | grep -q .; then
            continue
        fi
        new="${SHARED_RENAMES[$legacy]}"
        printf "${CYAN}Removing legacy %s (will be recreated as %s on next devbox start)${NC}\n" "$legacy" "$new"
        docker stop "$legacy" >/dev/null 2>&1 || true
        docker rm "$legacy" >/dev/null
        migrated=$((migrated + 1))
    done
    if [ "$migrated" -gt 0 ]; then
        printf "${GREEN}Migrated %d legacy shared-infra container(s).${NC}\n" "$migrated"
    fi
}

case "${1:-}" in
    --help|-h)
        usage
        exit 0
        ;;
    --check)
        legacy_exists
        ;;
    --auto|"")
        migrate
        ;;
    *)
        printf "${RED}Unknown flag: %s${NC}\n" "$1" >&2
        usage >&2
        exit 2
        ;;
esac
