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

# Isolate the DNS surface from the user's real ~/.config/devbox/dns.conf by
# pointing every load at a per-test tmp file.
_TMP_DNS_CONF="$(mktemp)"
export DEVBOX_DNS_CONF="$_TMP_DNS_CONF"
trap 'rm -f "$_TMP_DNS_CONF"' EXIT

# Reset dns.conf cache + on-disk content. Pass key=value pairs to seed.
seed_dns_conf() {
    devbox::reset_dns_cache
    : > "$_TMP_DNS_CONF"
    local line
    for line in "$@"; do
        printf '%s\n' "$line" >> "$_TMP_DNS_CONF"
    done
}

# Force "no dns.conf" by pointing at a non-existent file.
clear_dns_conf() {
    devbox::reset_dns_cache
    rm -f "$_TMP_DNS_CONF"
}

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

# --- devbox::route_domain (default = test when dns.conf absent) --------------

clear_dns_conf
assert_eq "route_domain default"            "test"      "$(devbox::route_domain)"
assert_eq "external_provider default"       "sslip.io"  "$(devbox::external_provider)"

# active_domain overridden via dns.conf
seed_dns_conf "active_domain=127.0.0.1.sslip.io" "external_provider=sslip.io"
assert_eq "route_domain external override"  "127.0.0.1.sslip.io"   "$(devbox::route_domain)"
assert_eq "external_provider from conf"     "sslip.io"             "$(devbox::external_provider)"

# external_provider override is honored
seed_dns_conf "active_domain=test" "external_provider=nip.io"
assert_eq "route_domain local from conf"    "test"      "$(devbox::route_domain)"
assert_eq "external_provider nip.io"        "nip.io"    "$(devbox::external_provider)"

# Comments + whitespace tolerated; unknown keys ignored. Use *non-default*
# values on both sides so a parser that silently drops the line cannot pass
# this assertion by falling back to the built-in default.
seed_dns_conf \
    "# leading comment" \
    "" \
    "  preferred=auto   # trailing comment" \
    "active_domain = 127.0.0.1.sslip.io " \
    " external_provider = nip.io  # spaces around = on both sides" \
    "bogus_key=ignored"
assert_eq "dns.conf whitespace tolerant active_domain"   "127.0.0.1.sslip.io"  "$(devbox::route_domain)"
assert_eq "dns.conf whitespace tolerant external"        "nip.io"              "$(devbox::external_provider)"

# --- devbox::route_hosts (always dual-emits local + external) ----------------

seed_dns_conf "active_domain=test" "external_provider=sslip.io"

expected_with_port=$'3000.foo.test\n3000.foo.127.0.0.1.sslip.io'
assert_eq "route_hosts w/ port"      "$expected_with_port"   "$(devbox::route_hosts foo 3000)"

expected_no_port=$'foo.test\nfoo.127.0.0.1.sslip.io'
assert_eq "route_hosts no port"      "$expected_no_port"     "$(devbox::route_hosts foo)"

# Mode switch (active_domain → external) must NOT change route_hosts output —
# both URL forms always coexist in Traefik routes.
seed_dns_conf "active_domain=127.0.0.1.sslip.io" "external_provider=sslip.io"
assert_eq "route_hosts unchanged in ext mode" "$expected_with_port" "$(devbox::route_hosts foo 3000)"

# Custom external_provider flows into the external hostname.
seed_dns_conf "active_domain=test" "external_provider=nip.io"
expected_nipio=$'3000.foo.test\n3000.foo.127.0.0.1.nip.io'
assert_eq "route_hosts uses nip.io"  "$expected_nipio"       "$(devbox::route_hosts foo 3000)"

# --- devbox::route_host_display (single hostname per active mode) ------------

seed_dns_conf "active_domain=test" "external_provider=sslip.io"
assert_eq "display local w/ port"    "3000.foo.test"         "$(devbox::route_host_display foo 3000)"
assert_eq "display local no port"    "foo.test"              "$(devbox::route_host_display foo)"

seed_dns_conf "active_domain=127.0.0.1.sslip.io" "external_provider=sslip.io"
assert_eq "display external w/ port" "3000.foo.127.0.0.1.sslip.io"  "$(devbox::route_host_display foo 3000)"
assert_eq "display external no port" "foo.127.0.0.1.sslip.io"       "$(devbox::route_host_display foo)"

# No dns.conf → defaults (test).
clear_dns_conf
assert_eq "display default w/ port"  "3000.foo.test"         "$(devbox::route_host_display foo 3000)"
assert_eq "display default no port"  "foo.test"              "$(devbox::route_host_display foo)"

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
