#!/bin/bash
set -euo pipefail
# One-shot migration: rewrite Traefik dynamic route configs that still carry
# the dead `*.127.0.0.1.traefik.me` hostname into the dual-emit form produced
# by `devbox::route_hosts` (local `<port>.<project>.test` || external
# `<port>.<project>.127.0.0.1.<provider>`). Triggered automatically by
# `devbox update`.
#
# Why: ADR 0007 — `traefik.me` external wildcard DNS stopped resolving (May
# 2026). Existing dynamic configs reference a host Traefik will never match,
# so every devbox URL the user accumulated before Phase 1-4 is broken until
# the rule is rewritten. Active migration pattern (ADR 0005 amendment) —
# warn-only would leave the user with N hand-edits.
#
# Strategy:
#   - Filename `<container>-<port>.yml` (see docker-run.sh apply_port_routes)
#     gives us container + port without parsing YAML.
#   - Build a fresh dual-`Host()` rule via `devbox::route_hosts` and rewrite
#     the file in place. Bind-mount-safe (`cat > file`, never `rm + cp`) per
#     the Docker Desktop inode-snapshot gotcha documented in ADR 0007.
#   - If `~/.config/devbox/dns.conf` is missing, run `devbox dns-install`
#     (auto mode) first so the regenerated configs and the host resolver
#     end up consistent in one update pass.
#
# This script is idempotent: re-running it on already-migrated configs is a
# no-op (the literal `traefik.me` is the only trigger).

# Use $'...' so the variables hold real ESC chars; printf '%s' substitutes
# them verbatim (no second escape pass needed, unlike "${VAR}" formats).
CYAN=$'\033[1;36m'; YELLOW=$'\033[1;33m'; GREEN=$'\033[1;32m'; RED=$'\033[1;31m'; NC=$'\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEVBOX_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source-path=SCRIPTDIR source=../lib/naming.sh disable=SC1091
source "$DEVBOX_DIR/lib/naming.sh"

TRAEFIK_CONFIG_DIR="$HOME/.config/devbox/traefik/dynamic"
DNS_CONF_FILE="${DEVBOX_DNS_CONF:-$HOME/.config/devbox/dns.conf}"

usage() {
    cat <<USAGE
Usage: migrate-traefik-me-routes.sh [--check | --auto | --help]

  --check    Exit 0 iff at least one dynamic Traefik config still references
             traefik.me. Used by 'devbox update' to decide whether to run.
  --auto     Run the migration non-interactively (default).
  --help     Show this message.
USAGE
}

# Echo every .yml file under TRAEFIK_CONFIG_DIR that contains the literal
# 'traefik.me'. Empty output = nothing to migrate. `grep -l` would be terser
# but a missing directory or zero-match glob aborts the pipeline under
# `set -e`; explicit iteration keeps the failure modes predictable.
list_stale_configs() {
    [ -d "$TRAEFIK_CONFIG_DIR" ] || return 0
    local f
    for f in "$TRAEFIK_CONFIG_DIR"/*.yml; do
        [ -f "$f" ] || continue
        if grep -q 'traefik\.me' "$f"; then
            printf '%s\n' "$f"
        fi
    done
}

# Rewrite one dynamic config in place using the current dual-host template.
# Filename layout `<container>-<port>.yml` is the contract owned by
# apply_port_routes in docker-run.sh; mirroring the YAML body here is
# deliberate duplication — this script is a one-shot and the next
# apply_port_routes invocation (e.g. `devbox port`) will overwrite anyway.
rewrite_config() {
    local f="$1"
    local base port container project router_name host_rule sep="" host
    base="$(basename "$f" .yml)"
    port="${base##*-}"
    container="${base%-*}"
    project="${container#devbox-}"
    router_name="${container}-${port}"

    if [ -z "$port" ] || [ -z "$container" ] || [ "$container" = "$base" ]; then
        printf "  ${YELLOW}skip %s — filename does not match <container>-<port>.yml${NC}\n" "$f" >&2
        return 1
    fi

    host_rule=""
    while IFS= read -r host; do
        host_rule+="${sep}Host(\`${host}\`)"
        sep=" || "
    done < <(devbox::route_hosts "$project" "$port")

    cat > "$f" <<YAML
http:
  routers:
    ${router_name}:
      rule: "${host_rule}"
      entryPoints:
        - web
      service: ${router_name}
  services:
    ${router_name}:
      loadBalancer:
        servers:
          - url: "http://${container}:${port}"
YAML
}

main() {
    local mode="${1:-}"
    case "$mode" in
        --help|-h) usage; exit 0 ;;
        --check)
            [ -n "$(list_stale_configs)" ] && exit 0
            exit 1
            ;;
        --auto|""|--run) ;;
        *)
            printf "${RED}Unknown flag: %s${NC}\n" "$mode" >&2
            usage >&2
            exit 2
            ;;
    esac

    local stale
    stale="$(list_stale_configs)"
    if [ -z "$stale" ]; then
        printf '%sNo traefik.me references in dynamic configs. Nothing to migrate.%s\n' "$GREEN" "$NC"
        exit 0
    fi

    # Ensure dns.conf exists before rewriting configs — the regenerated
    # dual-host rules emit `<project>.test` URLs that need the host resolver
    # to actually load in a browser. dns-install handles the per-OS resolver
    # setup and falls back to external mode loudly on conflict, so we let it
    # decide; we just trigger it when the user has never run it before.
    if [ ! -f "$DNS_CONF_FILE" ]; then
        printf '%s==> dns.conf missing — running "devbox dns-install" to wire up the host resolver%s\n' "$CYAN" "$NC"
        if ! "$DEVBOX_DIR/scripts/dns-install.sh" install --auto; then
            printf '%sWARN: dns-install reported errors; continuing with config rewrite anyway.%s\n' "$YELLOW" "$NC" >&2
            printf '%s      Run "devbox dns-status" afterwards to diagnose.%s\n' "$YELLOW" "$NC" >&2
        fi
        # dns-install rewrote dns.conf in another process scope; drop our
        # in-memory naming cache so route_hosts picks up the chosen mode.
        devbox::reset_dns_cache
    fi

    local count=0
    local f
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        if rewrite_config "$f"; then
            count=$((count + 1))
        fi
    done <<< "$stale"

    printf '\n%sRewrote %d Traefik dynamic config(s).%s\n' "$GREEN" "$count" "$NC"
    printf '%sURL formats now active (dual-Host rule, both work simultaneously):%s\n' "$CYAN" "$NC"
    printf '  local mode:    http://<port>.<project>.%s\n' "$DEVBOX_LOCAL_TLD"
    printf '  external mode: http://<port>.<project>.127.0.0.1.%s\n' "$(devbox::external_provider)"
}

main "$@"
