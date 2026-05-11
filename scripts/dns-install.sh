#!/bin/bash
set -euo pipefail
# Per-OS host-side DNS resolver setup so *.test hostnames route to 127.0.0.1
# (the dnsmasq container started by docker-run.sh::bootstrap_dns). Companion
# to ADR 0007.
#
# Actions:
#   install   detect platform, configure resolver, verify, persist mode
#   status    show platform + active mode + resolver-file state + verification
#   uninstall remove resolver entries and ~/.config/devbox/dns.conf
#
# Mode preference is persisted in ~/.config/devbox/dns.conf
# (override path with DEVBOX_DNS_CONF). lib/naming.sh parses the file
# strictly; we write it with a key=value updater that preserves unknown
# lines.
#
# Failures cascade to external mode rather than aborting: WARNINGS=()
# collects every issue and prints a colored end-summary so the user knows
# exactly which mode they ended up in and why.

CYAN='\033[1;36m'; YELLOW='\033[1;33m'; GREEN='\033[1;32m'; RED='\033[1;31m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEVBOX_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source-path=SCRIPTDIR source=../lib/naming.sh disable=SC1091
source "$DEVBOX_DIR/lib/naming.sh"

DNS_CONF_FILE="${DEVBOX_DNS_CONF:-$HOME/.config/devbox/dns.conf}"
DEFAULT_EXTERNAL_DOMAIN="127.0.0.1.sslip.io"
DEFAULT_EXTERNAL_PROVIDER="sslip.io"

WARNINGS=()
_warn() {
    WARNINGS+=("$1")
    printf "${YELLOW}WARN: %s${NC}\n" "$1" >&2
}
_info() { printf "${CYAN}%s${NC}\n" "$*"; }
_ok()   { printf "${GREEN}%s${NC}\n" "$*"; }
_fail() { printf "${RED}%s${NC}\n" "$*" >&2; }

usage() {
    cat <<USAGE
Usage: dns-install.sh [install] [--local | --external | --auto]
       dns-install.sh status
       dns-install.sh uninstall

Actions:
  install      Configure host resolver so *.test → 127.0.0.1 (default).
  status       Show platform, active mode, resolver state, verification.
  uninstall    Remove resolver config (per OS) and dns.conf.

Mode flags (install only):
  --auto       Try local; fall back to external on conflict/failure (default).
  --local      Force local mode; do not fall back.
  --external   Skip resolver setup; persist external (*.${DEFAULT_EXTERNAL_DOMAIN}).
USAGE
}

# --- Platform detection ------------------------------------------------------

# Returns one of: macos | wsl2 | linux-resolved | linux-nm | unsupported.
# WSL2 is checked before generic Linux because it needs two-sided setup
# (Linux-internal resolver + Windows NRPT) that other Linux variants do not.
_dns::detect_platform() {
    local uname_s
    uname_s="$(uname -s 2>/dev/null || echo Unknown)"
    case "$uname_s" in
        Darwin) echo "macos"; return 0 ;;
        Linux)  ;;
        *) echo "unsupported"; return 0 ;;
    esac
    if grep -qi microsoft /proc/version 2>/dev/null; then
        echo "wsl2"
        return 0
    fi
    if command -v systemctl >/dev/null 2>&1 \
        && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        echo "linux-resolved"
        return 0
    fi
    if _dns::nm_dnsmasq_enabled; then
        echo "linux-nm"
        return 0
    fi
    echo "unsupported"
}

# Check whether NetworkManager is configured to use the dnsmasq plugin
# (the only mode where the NM drop-in approach works).
_dns::nm_dnsmasq_enabled() {
    local rc=0
    grep -hE '^[[:space:]]*dns[[:space:]]*=' \
        /etc/NetworkManager/NetworkManager.conf \
        /etc/NetworkManager/conf.d/*.conf 2>/dev/null \
        | grep -q dnsmasq || rc=$?
    return "$rc"
}

# --- Pre-flight --------------------------------------------------------------

# Is port 53 currently held by something that would conflict with us?
# Returns 0 (yes) on conflict; 1 if free or already ours.
#
# Docker publishes devbox_dns on 127.0.0.1:53 specifically. The conflict
# set is therefore narrow: anything bound to 127.0.0.1:53 itself, or to a
# wildcard (0.0.0.0:53 / *:53 / [::]:53 / [::1]:53) that would also serve
# 127.0.0.1. Resolver listeners on *other* loopback addresses are fine:
#  - systemd-resolved listens on 127.0.0.53:53
#  - NetworkManager-dnsmasq listens on 127.0.1.1:53
# Both coexist with a Docker bind on 127.0.0.1:53, and the per-TLD routing
# we install (`Domains=~test` / `server=/test/...`) is what makes them
# forward .test queries into our container.
_dns::port_53_held_by_other() {
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx devbox_dns; then
        return 1
    fi
    local listeners=""
    if command -v ss >/dev/null 2>&1; then
        listeners="$(ss -lntu 2>/dev/null | awk 'NR>1 {print $5}')"
    elif command -v lsof >/dev/null 2>&1; then
        listeners="$({ lsof -nP -iTCP:53 -sTCP:LISTEN 2>/dev/null
                       lsof -nP -iUDP:53 2>/dev/null
                     } | awk 'NR>1 {print $9}')"
    else
        return 1
    fi
    [ -z "$listeners" ] && return 1
    local rc=1
    printf '%s\n' "$listeners" \
        | grep -qE '^(127\.0\.0\.1|0\.0\.0\.0|\*|\[::\]|\[::1\]):53$' && rc=0
    return "$rc"
}

_dns::sudo_available() {
    command -v sudo >/dev/null 2>&1
}

# --- Resolver writers (per platform) -----------------------------------------

_dns::install_macos() {
    local target="/etc/resolver/$DEVBOX_LOCAL_TLD"
    _info "Installing $target (sudo)..."
    if ! _dns::sudo_available; then
        _warn "sudo not available — cannot write $target"
        return 1
    fi
    # /etc/resolver does not exist on a fresh macOS — the Apple Resolver
    # framework only reads it when present. Create it before the first
    # entry; subsequent installs are no-ops thanks to `-p`.
    if ! sudo mkdir -p "$(dirname "$target")"; then
        _warn "Failed to create $(dirname "$target")"
        return 1
    fi
    if ! echo "nameserver 127.0.0.1" | sudo tee "$target" >/dev/null; then
        _warn "Failed to write $target"
        return 1
    fi
}

_dns::install_linux_resolved() {
    local drop="/etc/systemd/resolved.conf.d/devbox.conf"
    _info "Installing systemd-resolved drop-in $drop (sudo)..."
    if ! _dns::sudo_available; then
        _warn "sudo not available — cannot write $drop"
        return 1
    fi
    sudo mkdir -p "$(dirname "$drop")"
    if ! printf '%s\n' \
        "# Managed by devbox dns-install — do not edit." \
        "[Resolve]" \
        "DNS=127.0.0.1" \
        "Domains=~$DEVBOX_LOCAL_TLD" \
        | sudo tee "$drop" >/dev/null; then
        _warn "Failed to write $drop"
        return 1
    fi
    if ! sudo systemctl restart systemd-resolved 2>/dev/null; then
        _warn "systemd-resolved restart failed (drop-in written but not active)"
        return 1
    fi
}

_dns::install_linux_nm() {
    local drop="/etc/NetworkManager/dnsmasq.d/devbox.conf"
    _info "Installing NetworkManager-dnsmasq drop-in $drop (sudo)..."
    if ! _dns::sudo_available; then
        _warn "sudo not available — cannot write $drop"
        return 1
    fi
    sudo mkdir -p "$(dirname "$drop")"
    if ! echo "server=/$DEVBOX_LOCAL_TLD/127.0.0.1" \
        | sudo tee "$drop" >/dev/null; then
        _warn "Failed to write $drop"
        return 1
    fi
    if ! sudo systemctl reload NetworkManager 2>/dev/null; then
        _warn "NetworkManager reload failed (drop-in written but not active)"
        return 1
    fi
}

# WSL2 is two-sided: the WSL2 distro needs systemd-resolved (for WSL2-side
# curl) and the Windows host needs an NRPT rule (for browser + native Windows
# tools). Both ultimately route to 127.0.0.1:53 inside WSL2 via WSL2
# localhost forwarding. Either side may fail independently; we keep what
# worked and warn loudly about the rest. Returns success if at least one
# side is configured (callers treat that as "local mode is at least
# partially functional").
_dns::install_wsl2() {
    local linux_ok=0 windows_ok=0

    if command -v systemctl >/dev/null 2>&1 \
        && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        if _dns::install_linux_resolved; then
            linux_ok=1
        fi
    else
        _warn "systemd-resolved not active in this WSL2 distro — WSL2-side .test won't resolve. Enable it via /etc/wsl.conf [boot] systemd=true."
    fi

    if command -v powershell.exe >/dev/null 2>&1; then
        if _dns::install_wsl2_nrpt; then
            windows_ok=1
        fi
    else
        _warn "powershell.exe not found — cannot configure Windows NRPT. Run from a WSL2 distro with Windows interop enabled."
    fi

    if [ "$linux_ok" -eq 0 ] && [ "$windows_ok" -eq 0 ]; then
        return 1
    fi
}

# Encode the NRPT-add script as UTF-16LE base64 so the elevated PowerShell
# child reads it as a single -EncodedCommand argument, side-stepping the
# nested quoting nightmare of Start-Process -ArgumentList. UAC prompt
# appears here; user declining is detected by Get-DnsClientNrptRule
# returning the rule absent after the call.
_dns::install_wsl2_nrpt() {
    if ! command -v iconv >/dev/null 2>&1 || ! command -v base64 >/dev/null 2>&1; then
        _warn "iconv / base64 missing — cannot encode PowerShell command for NRPT setup."
        return 1
    fi
    local tld="$DEVBOX_LOCAL_TLD"
    local ps_cmd
    ps_cmd="if (-not (Get-DnsClientNrptRule -ErrorAction SilentlyContinue | Where-Object { \$_.Namespace -eq '.${tld}' -and \$_.NameServers -contains '127.0.0.1' })) { Add-DnsClientNrptRule -Namespace '.${tld}' -NameServers '127.0.0.1' }"
    local encoded
    encoded="$(printf '%s' "$ps_cmd" | iconv -t UTF-16LE | base64 -w0)"
    _info "Adding Windows NRPT rule (UAC will prompt)..."
    if ! powershell.exe -NoProfile -Command \
        "Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile','-EncodedCommand','$encoded'" \
        >/dev/null 2>&1; then
        _warn "Windows NRPT setup failed or UAC declined — Windows browser will not resolve .${tld} URLs in local mode."
        return 1
    fi
}

# --- Post-verify -------------------------------------------------------------

# Returns 0 iff a probe *.test hostname resolves to 127.0.0.1. Tries libc
# resolver first (honors /etc/resolver on macOS, NRPT on Windows-as-WSL2-
# host, systemd-resolved on Linux), then falls back to dscacheutil (macOS)
# and `dig @127.0.0.1` (direct query to our dnsmasq).
_dns::resolver_works() {
    local probe="devbox-probe-$$.${DEVBOX_LOCAL_TLD}"
    if command -v getent >/dev/null 2>&1 \
        && getent hosts "$probe" 2>/dev/null | grep -q '127\.0\.0\.1'; then
        return 0
    fi
    if command -v dscacheutil >/dev/null 2>&1 \
        && dscacheutil -q host -a name "$probe" 2>/dev/null | grep -q '127\.0\.0\.1'; then
        return 0
    fi
    if command -v dig >/dev/null 2>&1 \
        && dig +short +time=1 +tries=1 "$probe" @127.0.0.1 2>/dev/null | grep -q '127\.0\.0\.1'; then
        return 0
    fi
    return 1
}

# --- dns.conf writer ---------------------------------------------------------

# Atomically rewrite ~/.config/devbox/dns.conf, replacing the values for
# `preferred`, `active_domain`, and `external_provider` while leaving any
# unknown lines and comments untouched.
_dns::write_mode() {
    local preferred="$1" active_domain="$2" provider="${3:-$DEFAULT_EXTERNAL_PROVIDER}"
    local conf="$DNS_CONF_FILE"
    mkdir -p "$(dirname "$conf")"
    local tmp
    tmp="$(mktemp "${conf}.XXXXXX")"
    if [ -f "$conf" ]; then
        awk -v p="$preferred" -v ad="$active_domain" -v pr="$provider" '
            BEGIN { seen_p=0; seen_ad=0; seen_pr=0 }
            /^[[:space:]]*preferred[[:space:]]*=/         { print "preferred=" p;         seen_p=1;  next }
            /^[[:space:]]*active_domain[[:space:]]*=/     { print "active_domain=" ad;    seen_ad=1; next }
            /^[[:space:]]*external_provider[[:space:]]*=/ { print "external_provider=" pr; seen_pr=1; next }
            { print }
            END {
                if (!seen_p)  print "preferred=" p
                if (!seen_ad) print "active_domain=" ad
                if (!seen_pr) print "external_provider=" pr
            }
        ' "$conf" > "$tmp"
    else
        {
            echo "# Devbox DNS preferences — managed by 'devbox dns-install'."
            echo "preferred=$preferred"
            echo "active_domain=$active_domain"
            echo "external_provider=$provider"
        } > "$tmp"
    fi
    mv "$tmp" "$conf"
    devbox::reset_dns_cache
}

# --- Install orchestration ---------------------------------------------------

# Mode preferences: auto | local | external
#  - external          → no resolver setup, persist external mode.
#  - local             → setup required; fail loud on any error.
#  - auto (default)    → try local; fall to external on conflict or write fail.
#                         A post-write verify failure stays in local mode and
#                         only warns — bootstrap_dns has not started dnsmasq
#                         yet on first install, so probing now would fall back
#                         spuriously.
_dns::install() {
    local mode_pref="${1:-auto}"
    local platform
    platform="$(_dns::detect_platform)"
    _info "Detected platform: $platform"
    _info "Preferred mode:    $mode_pref"

    if [ "$mode_pref" = "external" ]; then
        _dns::write_mode external "$DEFAULT_EXTERNAL_DOMAIN" "$DEFAULT_EXTERNAL_PROVIDER"
        _ok "External mode active. URLs: <port>.<project>.${DEFAULT_EXTERNAL_DOMAIN}"
        return 0
    fi

    if _dns::port_53_held_by_other; then
        _warn "Port 53 is in use by another process — local mode would conflict."
        if [ "$mode_pref" = "local" ]; then
            _fail "--local requested but port 53 is busy. Aborting."
            return 1
        fi
        _info "Falling back to external mode."
        _dns::write_mode external "$DEFAULT_EXTERNAL_DOMAIN" "$DEFAULT_EXTERNAL_PROVIDER"
        _ok "External mode active."
        return 0
    fi

    local setup_rc=0
    case "$platform" in
        macos)          _dns::install_macos          || setup_rc=$? ;;
        linux-resolved) _dns::install_linux_resolved || setup_rc=$? ;;
        linux-nm)       _dns::install_linux_nm       || setup_rc=$? ;;
        wsl2)           _dns::install_wsl2           || setup_rc=$? ;;
        unsupported)
            _warn "Unsupported platform — cannot configure host resolver."
            setup_rc=1
            ;;
    esac

    if [ "$setup_rc" -ne 0 ]; then
        if [ "$mode_pref" = "local" ]; then
            _fail "--local requested but resolver setup failed."
            return 1
        fi
        _info "Resolver setup failed — falling back to external mode."
        _dns::write_mode external "$DEFAULT_EXTERNAL_DOMAIN" "$DEFAULT_EXTERNAL_PROVIDER"
        _ok "External mode active. URLs: <port>.<project>.${DEFAULT_EXTERNAL_DOMAIN}"
        return 0
    fi

    _dns::write_mode local "$DEVBOX_LOCAL_TLD" "$DEFAULT_EXTERNAL_PROVIDER"

    if _dns::resolver_works; then
        _ok "Local mode active. URLs: <port>.<project>.${DEVBOX_LOCAL_TLD}"
        return 0
    fi

    _warn "Post-install verification failed: *.${DEVBOX_LOCAL_TLD} does not currently resolve to 127.0.0.1. This is expected if devbox_dns is not running yet — start a devbox or run 'devbox dns-install status' after the first container starts."
    _ok "Local mode persisted. Resolver files are in place; dnsmasq will be started by the next 'devbox <project>'."
}

# --- Status ------------------------------------------------------------------

_dns::status() {
    local platform
    platform="$(_dns::detect_platform)"
    echo "Platform:           $platform"
    echo "Active domain:      $(devbox::route_domain)"
    echo "External provider:  $(devbox::external_provider)"
    if [ -f "$DNS_CONF_FILE" ]; then
        echo "dns.conf:           $DNS_CONF_FILE (present)"
    else
        echo "dns.conf:           $DNS_CONF_FILE (missing — defaults in effect)"
    fi
    case "$platform" in
        macos)
            local r="/etc/resolver/$DEVBOX_LOCAL_TLD"
            echo "Resolver file:      $r $([ -f "$r" ] && echo "(present)" || echo "(missing)")"
            ;;
        linux-resolved|wsl2)
            local d="/etc/systemd/resolved.conf.d/devbox.conf"
            echo "Resolved drop-in:   $d $([ -f "$d" ] && echo "(present)" || echo "(missing)")"
            ;;
        linux-nm)
            local d="/etc/NetworkManager/dnsmasq.d/devbox.conf"
            echo "NM drop-in:         $d $([ -f "$d" ] && echo "(present)" || echo "(missing)")"
            ;;
    esac
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx devbox_dns; then
        echo "Resolver container: devbox_dns (running)"
    elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx devbox_dns; then
        echo "Resolver container: devbox_dns (stopped — starts with next devbox)"
    else
        echo "Resolver container: devbox_dns (not created — starts with next devbox)"
    fi
    echo
    if _dns::resolver_works; then
        _ok "Verification: *.${DEVBOX_LOCAL_TLD} resolves to 127.0.0.1."
    elif [ "$(devbox::route_domain)" = "$DEVBOX_LOCAL_TLD" ]; then
        _warn "Verification: *.${DEVBOX_LOCAL_TLD} does NOT currently resolve to 127.0.0.1. Ensure devbox_dns is running ('devbox <project>')."
    else
        echo "Verification: skipped (external mode active)."
    fi
}

# --- Uninstall ---------------------------------------------------------------

_dns::uninstall() {
    local platform
    platform="$(_dns::detect_platform)"
    _info "Uninstalling devbox DNS resolver config (platform: $platform)..."

    case "$platform" in
        macos)
            local r="/etc/resolver/$DEVBOX_LOCAL_TLD"
            if [ -f "$r" ]; then
                if _dns::sudo_available; then
                    sudo rm -f "$r"
                    echo "Removed $r"
                else
                    _warn "sudo not available — cannot remove $r"
                fi
            fi
            ;;
        linux-resolved)
            _dns::uninstall_resolved_drop_in
            ;;
        linux-nm)
            local d="/etc/NetworkManager/dnsmasq.d/devbox.conf"
            if [ -f "$d" ]; then
                if _dns::sudo_available; then
                    sudo rm -f "$d"
                    echo "Removed $d"
                    sudo systemctl reload NetworkManager 2>/dev/null \
                        || _warn "NetworkManager reload failed"
                else
                    _warn "sudo not available — cannot remove $d"
                fi
            fi
            ;;
        wsl2)
            _dns::uninstall_resolved_drop_in
            _dns::uninstall_wsl2_nrpt
            ;;
    esac

    if [ -f "$DNS_CONF_FILE" ]; then
        rm -f "$DNS_CONF_FILE"
        echo "Removed $DNS_CONF_FILE"
    fi
    devbox::reset_dns_cache
    _ok "Uninstall complete."
}

_dns::uninstall_resolved_drop_in() {
    local d="/etc/systemd/resolved.conf.d/devbox.conf"
    [ -f "$d" ] || return 0
    if ! _dns::sudo_available; then
        _warn "sudo not available — cannot remove $d"
        return 0
    fi
    sudo rm -f "$d"
    echo "Removed $d"
    sudo systemctl restart systemd-resolved 2>/dev/null \
        || _warn "systemd-resolved restart failed"
}

_dns::uninstall_wsl2_nrpt() {
    command -v powershell.exe >/dev/null 2>&1 || return 0
    if ! command -v iconv >/dev/null 2>&1 || ! command -v base64 >/dev/null 2>&1; then
        _warn "iconv / base64 missing — cannot remove Windows NRPT rule programmatically."
        return 0
    fi
    local tld="$DEVBOX_LOCAL_TLD"
    local ps_cmd
    ps_cmd="Get-DnsClientNrptRule -ErrorAction SilentlyContinue | Where-Object { \$_.Namespace -eq '.${tld}' -and \$_.NameServers -contains '127.0.0.1' } | Remove-DnsClientNrptRule -Force -ErrorAction SilentlyContinue"
    local encoded
    encoded="$(printf '%s' "$ps_cmd" | iconv -t UTF-16LE | base64 -w0)"
    _info "Removing Windows NRPT rule (UAC will prompt)..."
    powershell.exe -NoProfile -Command \
        "Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile','-EncodedCommand','$encoded'" \
        >/dev/null 2>&1 \
        || _warn "Windows NRPT removal failed or UAC declined."
}

# --- Argument dispatch -------------------------------------------------------

print_warnings() {
    [ "${#WARNINGS[@]}" -eq 0 ] && return 0
    echo
    printf "${RED}==> dns-install finished with %d warning(s):${NC}\n" "${#WARNINGS[@]}"
    local w
    for w in "${WARNINGS[@]}"; do
        printf "    ${YELLOW}- %s${NC}\n" "$w"
    done
}

main() {
    local action="install"
    local mode_pref="auto"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            install|status|uninstall) action="$1" ;;
            --local)     mode_pref="local" ;;
            --external)  mode_pref="external" ;;
            --auto)      mode_pref="auto" ;;
            --status)    action="status" ;;
            --uninstall) action="uninstall" ;;
            -h|--help)   usage; exit 0 ;;
            *) _fail "Unknown argument: $1"; usage >&2; exit 2 ;;
        esac
        shift
    done

    local rc=0
    case "$action" in
        install)   _dns::install "$mode_pref" || rc=$? ;;
        status)    _dns::status               || rc=$? ;;
        uninstall) _dns::uninstall            || rc=$? ;;
    esac
    [ "$action" != "status" ] && print_warnings
    return "$rc"
}

main "$@"
