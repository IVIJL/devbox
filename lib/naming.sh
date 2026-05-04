# shellcheck shell=bash
# =============================================================================
# Devbox project naming — single source of truth for derived names
# =============================================================================
# Sourced by docker-run.sh (host). Owns the format of:
#   - container name        devbox-<project>
#   - hostname              <project>
#   - per-project volumes   devbox-<project>-{history,docker}
#   - workspace alias       /workspace/<project>
#   - traefik route host    [<port>.]<project>.<DEVBOX_ROUTE_DOMAIN>
#
# All derivations go through `devbox::sanitize` so forward construction matches
# the reverse derivation patterns (`${container#devbox-}`, regex on volume
# names). See docs/adr/0005-project-naming-from-sanitized-basename.md.
# =============================================================================

# --- Constants ---------------------------------------------------------------
# Consumed by sourcing scripts; shellcheck can't see that.
# shellcheck disable=SC2034

DEVBOX_PROJECT_VOLUME_SUFFIXES=(history docker)
DEVBOX_ROUTE_DOMAIN="127.0.0.1.traefik.me"

# --- Public API --------------------------------------------------------------

# Sanitize an arbitrary string into a name safe for docker objects:
# replace runs of non-[A-Za-z0-9_.-] with a single dash, then trim leading
# and trailing dashes.
#
# Usage: devbox::sanitize <s>
devbox::sanitize() {
    echo "$1" | tr -cs 'a-zA-Z0-9_.-' '-' | sed 's/^-//;s/-$//'
}

# Compute a `devbox-<project>-<suffix>` volume name.
#
# Usage: devbox::volume_name <project> <suffix>
devbox::volume_name() {
    printf 'devbox-%s-%s' "$1" "$2"
}

# Build a Traefik route host. With a port, prefixes `<port>.`; without a port,
# returns the bare `<project>.<domain>` form (used by `devbox ls`).
#
# Usage: devbox::route_host <project> [port]
devbox::route_host() {
    local project="$1" port="${2:-}"
    if [ -n "$port" ]; then
        printf '%s.%s.%s' "$port" "$project" "$DEVBOX_ROUTE_DOMAIN"
    else
        printf '%s.%s' "$project" "$DEVBOX_ROUTE_DOMAIN"
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
