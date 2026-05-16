#!/bin/bash
set -euo pipefail
# Idempotent host-side state for `devbox allow-for` (ADR 0009).
#
# Provisions two pieces of state that live outside Docker and therefore
# survive container teardown:
#   1. /var/log/devbox/allow-for/ as root:root 0755 — the harvest log
#      directory. Mounted read-write into every container so the in-container
#      root daemon can write reports; the node user (host UID 1000) can read
#      but cannot delete or overwrite, which is the tamper-proof guarantee
#      ADR 0009 §3-4 hangs the security argument on.
#   2. (WSL2 only) HKCU\Software\Classes\AppUserModelId\Devbox.AllowFor —
#      the toast notification AppId so the inline-COM PowerShell toast at
#      window close can launch File Explorer at the harvest log via WSL
#      UNC path. Missing AppId would degrade to a generic toast without
#      click-to-open; the log file is still written either way.
#
# Called from install.sh during fresh install (sole creator path) and from
# `devbox update` as a self-heal for existing installs that predate ADR 0009.
# Each step is independent: a missing powershell.exe on a non-Windows
# distro under WSL2 (rare but possible) degrades to a warning, not an
# overall failure — the log file remains the canonical record.
#
# Exits 0 when both steps end in their desired state ("created" or "already
# present"). Exits non-zero only when the directory step actually failed,
# since that breaks the feature; HKCU failure is informational.

ALLOW_FOR_LOG_DIR="/var/log/devbox/allow-for"
WSL_APP_ID="Devbox.AllowFor"

# --- Argument parsing --------------------------------------------------------
# `--quiet-if-noop` suppresses the per-step "already correct, skipping"
# stderr lines. install.sh calls without it (user expects a status report
# during a fresh install); the `devbox update` self-heal passes it so the
# common steady-state run is silent and only a real fix-up makes noise.
QUIET_IF_NOOP=false
for arg in "$@"; do
    case "$arg" in
        --quiet-if-noop) QUIET_IF_NOOP=true ;;
        --help|-h)
            cat <<'USAGE'
Usage: ensure-allow-for-host-state.sh [--quiet-if-noop]

Idempotently provision the host-side state `devbox allow-for` needs:
  - /var/log/devbox/allow-for/ owned root:root 0755
  - (WSL2 only) HKCU\...\AppUserModelId\Devbox.AllowFor toast AppId

Options:
  --quiet-if-noop   Stay silent when both pieces of state are already in
                    the desired shape. Created / repaired / failed steps
                    still print. Intended for the `devbox update` self-heal.
USAGE
            exit 0
            ;;
        *)
            printf '\033[1;31m==> ERROR: Unknown argument: %s\033[0m\n' "$arg" >&2
            exit 2
            ;;
    esac
done

# Diagnostics on stderr, free for callers (install.sh, docker-run.sh) to
# either suppress or forward. Stdout is unused so callers parsing rc alone
# never see noise.
CYAN='\033[1;36m'; YELLOW='\033[1;33m'; GREEN='\033[1;32m'; NC='\033[0m'
_info() { printf "${CYAN}==> %s${NC}\n" "$*" >&2; }
_ok()   { printf "${GREEN}==> %s${NC}\n" "$*" >&2; }
_warn() { printf "${YELLOW}==> WARN: %s${NC}\n" "$*" >&2; }
_msg()  { printf '  %s\n' "$*" >&2; }
_noop_msg() {
    $QUIET_IF_NOOP && return 0
    printf '  %s\n' "$*" >&2
}

is_wsl2() { grep -qi microsoft /proc/version 2>/dev/null; }

# Portable `stat` probe — emits `uid:gid:octal-mode` on stdout. GNU
# coreutils (Linux) uses `-c '%u:%g:%a'`; BSD `stat` on macOS uses
# `-f '%u:%g:%Lp'`. Try GNU first because it's the common host; fall
# back to BSD silently. Numeric uid/gid sidesteps the Linux-vs-macOS
# root-group name split (root vs wheel) — we compare against the
# numeric `0:0:755` invariant directly.
_stat_owner_mode() {
    local path="$1"
    stat -c '%u:%g:%a' "$path" 2>/dev/null \
        || stat -f '%u:%g:%Lp' "$path" 2>/dev/null
}

# --- Step 1: harvest log directory ------------------------------------------
# `sudo install -d` is naturally idempotent: creates if missing, resets
# perms when present. We probe with stat first to avoid an unnecessary sudo
# prompt — the `devbox update` self-heal calls into this script on every
# run, so the fast-path matters.
#
# Numeric `-o 0 -g 0` instead of `-o root -g root` because BSD `install`
# on macOS rejects the latter: root's primary group on macOS is `wheel`,
# not `root`, and the group lookup fails before any work happens. UID/GID 0
# is universal across both platforms.
ensure_log_dir() {
    if [ -d "$ALLOW_FOR_LOG_DIR" ]; then
        local stat_out
        stat_out="$(_stat_owner_mode "$ALLOW_FOR_LOG_DIR" || true)"
        if [ "$stat_out" = "0:0:755" ]; then
            _noop_msg "$ALLOW_FOR_LOG_DIR already root:root 0755 — skipping."
            return 0
        fi
    fi

    _info "Creating $ALLOW_FOR_LOG_DIR (root:root 0755) — sudo may prompt."
    if ! sudo install -d -o 0 -g 0 -m 0755 "$ALLOW_FOR_LOG_DIR"; then
        _warn "Failed to create $ALLOW_FOR_LOG_DIR — 'devbox allow-for' will not work until this is fixed."
        return 1
    fi
    _ok "$ALLOW_FOR_LOG_DIR ready."
}

# --- Step 2: WSL2 HKCU toast AppId ------------------------------------------
# HKCU writes never elevate, so this is a plain powershell.exe call (no
# Start-Process -Verb RunAs). The script is doubly idempotent: outer
# Test-Path skips the New-Item / Set-ItemProperty when the key already
# exists, and the final Test-Path returns the rc so a partial write
# (e.g. registry permission glitch) surfaces as a non-zero exit.
ensure_wsl_app_id() {
    is_wsl2 || return 0
    if ! command -v powershell.exe >/dev/null 2>&1; then
        _warn "powershell.exe not in PATH — cannot register $WSL_APP_ID toast AppId. Click-to-open notifications will fall back to silent close (log file is still written)."
        return 0
    fi

    # Distinct exit codes let bash differentiate no-op (key already
    # present) from a fresh create — only the create gets a visible "==>"
    # banner, so the steady-state self-heal stays silent under
    # --quiet-if-noop. Exit 1 covers a write that succeeded partially but
    # left Test-Path returning false; bash treats it as a soft failure.
    local ps_cmd
    ps_cmd="\$RegPath = 'HKCU:\\Software\\Classes\\AppUserModelId\\${WSL_APP_ID}'; if (Test-Path \$RegPath) { exit 0 }; New-Item -Path \$RegPath -Force | Out-Null; Set-ItemProperty -Path \$RegPath -Name DisplayName -Value 'Devbox'; if (Test-Path \$RegPath) { exit 10 } else { exit 1 }"
    local rc=0
    powershell.exe -NoProfile -Command "$ps_cmd" >/dev/null 2>&1 || rc=$?
    case "$rc" in
        0)
            _noop_msg "Windows toast AppId $WSL_APP_ID already registered — skipping."
            ;;
        10)
            _ok "Registered Windows toast AppId $WSL_APP_ID."
            ;;
        *)
            _warn "Failed to register Windows toast AppId $WSL_APP_ID (powershell rc=$rc) — 'devbox allow-for' will fall back to silent close (log file is still written)."
            ;;
    esac
}

ensure_log_dir
ensure_wsl_app_id
