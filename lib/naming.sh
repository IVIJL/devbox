# shellcheck shell=bash
# =============================================================================
# Devbox project naming — single source of truth for derived names
# =============================================================================
# Sourced by docker-run.sh (host). Owns the format of:
#   - container name        devbox-<project>
#   - hostname              <project>
#   - per-project volumes   devbox-<project>-{history,docker}
#   - workspace alias       /workspace/<project>
#   - traefik route hosts   [<port>.]<project>.<active-domain>     (display)
#                           [<port>.]<project>.test                (local)
#                           [<port>.]<project>.127.0.0.1.<ext>     (external)
#
# All derivations go through `devbox::sanitize` so forward construction matches
# the reverse derivation patterns (`${container#devbox-}`, regex on volume
# names). See docs/adr/0005-project-naming-from-sanitized-basename.md.
#
# DNS surface is dual-mode (local `.test` + external wildcard provider) per
# ADR 0007. `route_hosts` yields both forms for Traefik dual-`Host()` rules;
# `route_host_display` yields a single user-facing form based on the active
# mode in `~/.config/devbox/dns.conf` (overridable via `DEVBOX_DNS_CONF`).
# =============================================================================

# --- Constants ---------------------------------------------------------------
# Consumed by sourcing scripts; shellcheck can't see that.
# shellcheck disable=SC2034

DEVBOX_PROJECT_VOLUME_SUFFIXES=(history docker)

# Local TLD. RFC 2606 reserved for testing; chosen for browser/CLI parity
# (no baked-in browser fast-path like *.localhost has). Constant — not
# user-configurable. See ADR 0007 § "TLD: `.test` (not `.localhost`)".
DEVBOX_LOCAL_TLD="test"

# --- DNS config (lazy-loaded from dns.conf) ----------------------------------

# Internal cache. Read via devbox::route_domain / devbox::external_provider;
# reset via devbox::reset_dns_cache (used by tests and by dns-install after
# rewriting dns.conf within the same process).
_DEVBOX_DNS_CONF_LOADED=
_DEVBOX_ACTIVE_DOMAIN=
_DEVBOX_EXTERNAL_PROVIDER=

devbox::reset_dns_cache() {
    _DEVBOX_DNS_CONF_LOADED=
    _DEVBOX_ACTIVE_DOMAIN=
    _DEVBOX_EXTERNAL_PROVIDER=
}

# Parse ~/.config/devbox/dns.conf (or $DEVBOX_DNS_CONF) into the cache. The
# file format is `key=value` per line with `#` comments. We intentionally do
# *not* `source` it — strict parse, fixed key allow-list, no ambient pollution
# if a stray line slips in.
_devbox::load_dns_conf() {
    [ -n "$_DEVBOX_DNS_CONF_LOADED" ] && return 0
    _DEVBOX_DNS_CONF_LOADED=1
    _DEVBOX_ACTIVE_DOMAIN="$DEVBOX_LOCAL_TLD"
    _DEVBOX_EXTERNAL_PROVIDER="sslip.io"
    local conf="${DEVBOX_DNS_CONF:-$HOME/.config/devbox/dns.conf}"
    [ -f "$conf" ] || return 0
    local line key value
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -z "$line" ] && continue
        key="${line%%=*}"
        value="${line#*=}"
        [ "$key" = "$line" ] && continue
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        case "$key" in
            active_domain)     [ -n "$value" ] && _DEVBOX_ACTIVE_DOMAIN="$value" ;;
            external_provider) [ -n "$value" ] && _DEVBOX_EXTERNAL_PROVIDER="$value" ;;
        esac
    done < "$conf"
}

# --- Public API --------------------------------------------------------------

# Sanitize an arbitrary string into a name safe for docker objects AND for
# DNS labels (RFC 1034/1035 LDH): replace runs of non-[A-Za-z0-9-] with a
# single dash, then trim leading and trailing dashes.
#
# `_` and `.` are deliberately excluded — both are valid in docker container
# and volume names but not in DNS labels, and the same project name flows
# into the Traefik route host. Keeping the allowlist strict at LDH lets
# every derived name stay valid simultaneously.
#
# Usage: devbox::sanitize <s>
devbox::sanitize() {
    echo "$1" | tr -cs 'a-zA-Z0-9-' '-' | sed 's/^-//;s/-$//'
}

# Compute a `devbox-<project>-<suffix>` volume name.
#
# Usage: devbox::volume_name <project> <suffix>
devbox::volume_name() {
    printf 'devbox-%s-%s' "$1" "$2"
}

# Return the active route domain string (e.g. `test` for local mode,
# `127.0.0.1.sslip.io` for external mode). Defaults to `test` if dns.conf
# is absent or the field is unset.
devbox::route_domain() {
    _devbox::load_dns_conf
    printf '%s' "$_DEVBOX_ACTIVE_DOMAIN"
}

# Return the configured external wildcard DNS provider (e.g. `sslip.io`).
# Default `sslip.io`. Configurable so we are never locked to one vendor — see
# ADR 0007 § "External provider".
devbox::external_provider() {
    _devbox::load_dns_conf
    printf '%s' "$_DEVBOX_EXTERNAL_PROVIDER"
}

# Yield every Traefik route hostname for a project, one per line. Always
# emits both the local (`.test`) and the external (`.127.0.0.1.<provider>`)
# form so the generated dual-`Host()` rule keeps working across mode switches
# without regenerating dynamic configs (ADR 0007 § "Both URLs work
# simultaneously in Traefik").
#
# Usage: devbox::route_hosts <project> [port]
devbox::route_hosts() {
    local project="$1" port="${2:-}"
    _devbox::load_dns_conf
    local prefix=""
    [ -n "$port" ] && prefix="${port}."
    printf '%s%s.%s\n' "$prefix" "$project" "$DEVBOX_LOCAL_TLD"
    printf '%s%s.127.0.0.1.%s\n' "$prefix" "$project" "$_DEVBOX_EXTERNAL_PROVIDER"
}

# Yield the single user-facing hostname for the active mode. Used by display
# call sites (`devbox port`, `devbox ports`, `devbox ls`). Mode switching
# only changes what this prints; Traefik routes (built from route_hosts)
# are unaffected.
#
# Usage: devbox::route_host_display <project> [port]
devbox::route_host_display() {
    local project="$1" port="${2:-}"
    _devbox::load_dns_conf
    if [ -n "$port" ]; then
        printf '%s.%s.%s' "$port" "$project" "$_DEVBOX_ACTIVE_DOMAIN"
    else
        printf '%s.%s' "$project" "$_DEVBOX_ACTIVE_DOMAIN"
    fi
}

# Print a regex matching all per-project volume names. Derived from
# DEVBOX_PROJECT_VOLUME_SUFFIXES so adding a suffix updates every reverse
# match site.
#
# Usage: pattern=$(devbox::project_volume_regex)
devbox::project_volume_regex() {
    local IFS='|'
    printf '^devbox-.+-(%s)$' "${DEVBOX_PROJECT_VOLUME_SUFFIXES[*]}"
}

# Derive every name from a host filesystem path. Sanitizes the basename and
# exports DEVBOX_* globals.
#
# Usage: devbox::names_from_path <path>
devbox::names_from_path() {
    local path="$1"
    DEVBOX_PROJECT_NAME_RAW="$(basename "$path")"
    _devbox::derive_from_project_name "$(devbox::sanitize "$DEVBOX_PROJECT_NAME_RAW")"
}

# Derive every name from a user-supplied token (e.g. `devbox foo`). Sanitizes
# the token so the result is identical for `devbox foo bar` and `devbox foo-bar`
# — fixes the latent inconsistency at docker-run.sh attach-by-name.
#
# Usage: devbox::names_from_token <token>
devbox::names_from_token() {
    local token="$1"
    DEVBOX_PROJECT_NAME_RAW="$token"
    _devbox::derive_from_project_name "$(devbox::sanitize "$token")"
}

# --- Private -----------------------------------------------------------------

_devbox::derive_from_project_name() {
    DEVBOX_PROJECT_NAME="$1"
    DEVBOX_CONTAINER_NAME="devbox-${DEVBOX_PROJECT_NAME}"
    DEVBOX_HOSTNAME="${DEVBOX_PROJECT_NAME}"
    DEVBOX_VOL_HISTORY="$(devbox::volume_name "$DEVBOX_PROJECT_NAME" history)"
    DEVBOX_VOL_DOCKER="$(devbox::volume_name "$DEVBOX_PROJECT_NAME" docker)"
    DEVBOX_WORKSPACE_ALIAS="/workspace/${DEVBOX_PROJECT_NAME}"
}
