#!/bin/bash
# Plain-bash assertions for lib/naming.sh. Runs in any bash, no harness needed.
#
# Usage: bash tests/naming.sh
#
# Each assertion prints PASS/FAIL with a short label; non-zero exit on any FAIL.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=../lib/naming.sh disable=SC1091
source "$SCRIPT_DIR/../lib/naming.sh"

fail_count=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf 'PASS  %s\n' "$label"
    else
        printf 'FAIL  %s\n      expected: %q\n      actual:   %q\n' \
            "$label" "$expected" "$actual"
        fail_count=$((fail_count + 1))
    fi
}

# --- devbox::sanitize --------------------------------------------------------

assert_eq "sanitize ascii"           "my-app"     "$(devbox::sanitize "my-app")"
assert_eq "sanitize space"           "Foo-Bar"    "$(devbox::sanitize "Foo Bar")"
assert_eq "sanitize multi-space"     "a-b"        "$(devbox::sanitize "a   b")"
assert_eq "sanitize diacritics"      "v-ce"       "$(devbox::sanitize "více")"
assert_eq "sanitize underscore"      "foo-bar"    "$(devbox::sanitize "foo_bar")"
assert_eq "sanitize underscore run"  "foo-bar"    "$(devbox::sanitize "foo___bar")"
assert_eq "sanitize dot"             "foo-bar"    "$(devbox::sanitize "foo.bar")"
assert_eq "sanitize mixed bad"       "foo-bar"    "$(devbox::sanitize "foo_.bar")"
assert_eq "sanitize trim leading"    "x"          "$(devbox::sanitize "-x")"
assert_eq "sanitize trim trailing"   "x"          "$(devbox::sanitize "x-")"
assert_eq "sanitize idempotent"      "my-app"     "$(devbox::sanitize "$(devbox::sanitize "my app")")"

# --- devbox::volume_name -----------------------------------------------------

assert_eq "volume_name history"      "devbox-foo-history"   "$(devbox::volume_name foo history)"
assert_eq "volume_name docker"       "devbox-foo-docker"    "$(devbox::volume_name foo docker)"

# --- devbox::route_host ------------------------------------------------------

assert_eq "route_host w/ port"       "3000.foo.127.0.0.1.traefik.me"   "$(devbox::route_host foo 3000)"
assert_eq "route_host no port"       "foo.127.0.0.1.traefik.me"        "$(devbox::route_host foo)"

# --- devbox::project_volume_regex --------------------------------------------

assert_eq "project_volume_regex"     "^devbox-.+-(history|docker)$"     "$(devbox::project_volume_regex)"

# --- devbox::names_from_path -------------------------------------------------

devbox::names_from_path "/home/u/Projekty/devbox"
assert_eq "from_path PROJECT_NAME"       "devbox"                       "$DEVBOX_PROJECT_NAME"
assert_eq "from_path PROJECT_NAME_RAW"   "devbox"                       "$DEVBOX_PROJECT_NAME_RAW"
assert_eq "from_path CONTAINER_NAME"     "devbox-devbox"                "$DEVBOX_CONTAINER_NAME"
assert_eq "from_path HOSTNAME"           "devbox"                       "$DEVBOX_HOSTNAME"
assert_eq "from_path VOL_HISTORY"        "devbox-devbox-history"        "$DEVBOX_VOL_HISTORY"
assert_eq "from_path VOL_DOCKER"         "devbox-devbox-docker"         "$DEVBOX_VOL_DOCKER"
assert_eq "from_path WORKSPACE_ALIAS"    "/workspace/devbox"            "$DEVBOX_WORKSPACE_ALIAS"

# Path with space + diacritics (the latent-bug scenario from the plan)
devbox::names_from_path "/home/u/Code/Foo Bar"
assert_eq "from_path RAW kept"           "Foo Bar"                      "$DEVBOX_PROJECT_NAME_RAW"
assert_eq "from_path sanitized name"     "Foo-Bar"                      "$DEVBOX_PROJECT_NAME"
assert_eq "from_path sanitized container" "devbox-Foo-Bar"              "$DEVBOX_CONTAINER_NAME"
assert_eq "from_path sanitized hostname"  "Foo-Bar"                     "$DEVBOX_HOSTNAME"
assert_eq "from_path sanitized history"   "devbox-Foo-Bar-history"      "$DEVBOX_VOL_HISTORY"

# Path with underscore (the LDH-tightening scenario — RFC 1034/1035 forbids `_`)
devbox::names_from_path "/home/u/Projekty/foo_bar"
assert_eq "from_path underscore RAW"     "foo_bar"                      "$DEVBOX_PROJECT_NAME_RAW"
assert_eq "from_path underscore name"    "foo-bar"                      "$DEVBOX_PROJECT_NAME"
assert_eq "from_path underscore cont"    "devbox-foo-bar"               "$DEVBOX_CONTAINER_NAME"
assert_eq "from_path underscore host"    "foo-bar"                      "$DEVBOX_HOSTNAME"
assert_eq "from_path underscore vol"     "devbox-foo-bar-history"       "$DEVBOX_VOL_HISTORY"

# --- devbox::names_from_token ------------------------------------------------

# Plain token already in canonical form
devbox::names_from_token "my-app"
assert_eq "from_token CONTAINER_NAME"    "devbox-my-app"                "$DEVBOX_CONTAINER_NAME"
assert_eq "from_token PROJECT_NAME"      "my-app"                       "$DEVBOX_PROJECT_NAME"

# Idempotency fix: token with whitespace (idempotent with from_path output)
devbox::names_from_token "Foo Bar"
assert_eq "from_token sanitizes spaces"  "devbox-Foo-Bar"               "$DEVBOX_CONTAINER_NAME"

# --- summary -----------------------------------------------------------------

if [ "$fail_count" -gt 0 ]; then
    printf '\n%d test(s) failed.\n' "$fail_count" >&2
    exit 1
fi
printf '\nAll tests passed.\n'
