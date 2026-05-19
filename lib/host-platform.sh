# shellcheck shell=bash
# =============================================================================
# Devbox host-platform dispatch (ADR 0010 § Cross-platform abstraction)
# =============================================================================
# Single source of truth for per-OS branching on the host side. Sourced by
# host-side scripts that need to know which platform they run on or that
# need to launch host-only artifacts (Chrome, system users, notifications).
#
# Three platforms are supported, mirroring the rest of devbox's host story:
#   - linux  — native Linux desktop (X11/Wayland)
#   - wsl2   — Linux distro under WSL2 on Windows (WSLg renders GUIs)
#   - macos  — Darwin
#
# Why this file exists separately from `scripts/dns-install.sh`'s
# `_dns::detect_platform`: dns-install reports `linux-resolved` /
# `linux-nm` because the DNS install branch matters per stack. The
# agent-browser feature only needs the OS family, not the resolver
# variant. Keeping these two detect functions distinct prevents one
# concern (DNS install) from accidentally widening the contract of the
# other (host-platform dispatch). Both stay grep-able for `uname -s`.
#
# Functions are namespaced with the `host_platform::` prefix, matching
# the repo's existing `allow_for::`, `allowlist::`, `_mkcert::` style.
# =============================================================================

# --- Detection ---------------------------------------------------------------

# Echo one of: linux | wsl2 | macos. Non-zero on unknown OS.
#
# WSL2 is checked before generic Linux because it needs different binaries
# (PowerShell for toasts, %USERPROFILE% paths) and different Chrome
# semantics (Chrome runs as a Linux binary inside the WSL distro, rendered
# through WSLg — not the host Windows Chrome, which has no CDP we can
# trust). Detection uses /proc/sys/fs/binfmt_misc/WSLInterop as the
# primary signal (set by WSL itself, distro-agnostic), falling back to
# /proc/version content for older WSL builds.
host_platform::detect() {
    case "$(uname -s 2>/dev/null || echo Unknown)" in
        Darwin) printf 'macos\n'; return 0 ;;
        Linux)  ;;
        *)      return 1 ;;
    esac
    if [ -e /proc/sys/fs/binfmt_misc/WSLInterop ] \
        || grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
        printf 'wsl2\n'
        return 0
    fi
    printf 'linux\n'
}

# --- Chrome binary discovery -------------------------------------------------

# Echo the absolute path to an executable Chrome/Chromium binary, or fail
# (rc=1) with a clear stderr install hint naming the canonical command for
# the detected platform.
#
# Search order is documented inline per platform. WSL2 deliberately uses
# the Linux search because Host agent Chrome must render through WSLg as a
# Linux process — the host Windows Chrome is the user's personal browser
# (rejected in ADR 0010 considered options) and CDP through interop would
# punch through WSL's network namespace anyway.
host_platform::chrome_binary() {
    local platform
    if ! platform="$(host_platform::detect)"; then
        printf 'host_platform::chrome_binary: unknown OS (%s)\n' "$(uname -s)" >&2
        return 1
    fi

    local candidates=()
    case "$platform" in
        linux|wsl2)
            # PATH first (distro packages, user installs), then canonical
            # /usr/bin locations (Chrome's .deb / Chromium snap-shim).
            local name
            for name in google-chrome google-chrome-stable chromium chromium-browser; do
                local found
                found="$(command -v "$name" 2>/dev/null || true)"
                [ -n "$found" ] && candidates+=("$found")
            done
            local glob
            for glob in /usr/bin/google-chrome /usr/bin/google-chrome-stable \
                        /usr/bin/chromium /usr/bin/chromium-browser \
                        /snap/bin/chromium; do
                [ -x "$glob" ] && candidates+=("$glob")
            done
            ;;
        macos)
            # /Applications first (system-wide install — the default for
            # both Google Chrome.app and Chromium.app), then ~/Applications
            # for per-user installs.
            local app
            for app in \
                "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
                "/Applications/Chromium.app/Contents/MacOS/Chromium" \
                "${HOME}/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
                "${HOME}/Applications/Chromium.app/Contents/MacOS/Chromium"; do
                [ -x "$app" ] && candidates+=("$app")
            done
            ;;
    esac

    local cand
    for cand in "${candidates[@]+"${candidates[@]}"}"; do
        if [ -x "$cand" ]; then
            printf '%s\n' "$cand"
            return 0
        fi
    done

    case "$platform" in
        linux)
            printf 'host_platform::chrome_binary: no Chrome/Chromium found.\n' >&2
            printf '  Install one of:\n' >&2
            printf '    sudo apt-get install -y chromium      # Debian/Ubuntu\n' >&2
            printf '    sudo dnf install -y chromium          # Fedora/RHEL\n' >&2
            printf '    sudo pacman -S chromium               # Arch\n' >&2
            printf '  Or Google Chrome from https://www.google.com/chrome/\n' >&2
            ;;
        wsl2)
            printf 'host_platform::chrome_binary: no Chrome/Chromium found inside the WSL2 distro.\n' >&2
            printf '  Host agent Chrome runs as a Linux binary under WSLg, not the host Windows Chrome.\n' >&2
            printf '  Install inside this distro:\n' >&2
            printf '    sudo apt-get install -y chromium\n' >&2
            printf '  Or Google Chrome for Linux from https://www.google.com/chrome/\n' >&2
            ;;
        macos)
            printf 'host_platform::chrome_binary: no Chrome/Chromium found in /Applications or ~/Applications.\n' >&2
            printf '  Install one of:\n' >&2
            printf '    brew install --cask google-chrome\n' >&2
            printf '    brew install --cask chromium\n' >&2
            printf '  Or download Google Chrome from https://www.google.com/chrome/\n' >&2
            ;;
    esac
    return 1
}

# --- devbox-agent OS user ----------------------------------------------------

# Idempotently create the `devbox-agent` OS user that Host agent Chrome
# runs under (ADR 0010 § Actor 1). The OS identity is the primary defence
# against `file://` reads of the developer's home and download-to-autostart
# attacks; `--user-data-dir` alone does not change process write perms.
#
# Linux/WSL2 path uses `useradd` and accepts the system-account treatment
# (--system, nologin shell) — the agent never logs in interactively, so
# the system-account distinction has no downsides on Linux.
#
# macOS path uses `sysadminctl -addUser` and intentionally creates a
# regular user (not an underscore-prefixed system user). ADR 0010
# considered options block calls this out: `_devbox-agent` triggers
# LaunchServices edge cases (no notarisation prompts for downloads, hidden
# from login screen but still surfaces in some File Open dialogs, no
# Quartz seat by default) that complicate the visual-audit story. A
# regular user with a shell of `/usr/bin/false` is the simpler reliable
# shape.
host_platform::ensure_agent_user() {
    local platform
    if ! platform="$(host_platform::detect)"; then
        printf 'host_platform::ensure_agent_user: unknown OS (%s)\n' "$(uname -s)" >&2
        return 1
    fi

    case "$platform" in
        linux|wsl2)
            _host_platform::ensure_agent_user_linux
            ;;
        macos)
            _host_platform::ensure_agent_user_macos
            ;;
    esac
}

# --- Internal helpers --------------------------------------------------------

_host_platform::ensure_agent_user_linux() {
    if id devbox-agent >/dev/null 2>&1; then
        return 0
    fi

    # `useradd` (shadow) is the tool on Debian/Ubuntu/Fedora/RHEL/Arch/
    # openSUSE. Alpine ships only BusyBox `adduser` with different flag
    # syntax; install.sh's PM list (`apk`) supports Alpine explicitly,
    # so this branch must too.
    #
    # `/usr/sbin/nologin` is shadow's canonical path; BusyBox systems
    # put it at `/sbin/nologin`. Fall back to `/bin/false` if neither
    # exists — the account is never logged into interactively, so any
    # non-shell is equivalent here.
    local cand nologin_shell=""
    for cand in /usr/sbin/nologin /sbin/nologin /bin/false; do
        if [ -x "$cand" ]; then
            nologin_shell="$cand"
            break
        fi
    done
    if [ -z "$nologin_shell" ]; then
        printf 'host_platform::ensure_agent_user: no nologin/false shell found\n' >&2
        return 1
    fi

    if command -v useradd >/dev/null 2>&1; then
        # `--system` because the account is never logged into.
        # `--user-group` creates a matching `devbox-agent` group, which
        # the log-dir provisioning in later slices will add the
        # developer to (read-only on the proxy log).
        if ! sudo useradd --system --user-group \
                --create-home \
                --shell "$nologin_shell" \
                devbox-agent; then
            printf 'host_platform::ensure_agent_user: useradd failed for devbox-agent\n' >&2
            return 1
        fi
    elif command -v adduser >/dev/null 2>&1; then
        # BusyBox adduser (Alpine): -S system, -D no password,
        # -h home dir, -s shell. System users get an auto-created
        # matching group, equivalent to shadow's `--user-group`.
        if ! sudo adduser -S -D -h /home/devbox-agent \
                -s "$nologin_shell" devbox-agent; then
            printf 'host_platform::ensure_agent_user: adduser failed for devbox-agent\n' >&2
            return 1
        fi
    else
        printf 'host_platform::ensure_agent_user: neither useradd nor adduser found\n' >&2
        return 1
    fi
}

_host_platform::ensure_agent_user_macos() {
    if id devbox-agent >/dev/null 2>&1; then
        return 0
    fi

    # sysadminctl needs admin; sudo prompts the GUI for an admin password
    # (matches mkcert -install UX on macOS).
    #
    # `-password` is a mandatory argument: sysadminctl exits non-zero if
    # omitted. The account is never logged into interactively, so we
    # assign a random one-shot password; sudo from an admin account does
    # not need this password to launch Chrome as devbox-agent. The shell
    # is `/usr/bin/false` to additionally block `su devbox-agent`.
    local one_shot_password
    one_shot_password="$(openssl rand -base64 24 2>/dev/null \
        || dd if=/dev/urandom bs=18 count=1 2>/dev/null | base64)"

    if ! sudo sysadminctl -addUser devbox-agent \
            -fullName "Devbox Agent" \
            -password "$one_shot_password" \
            -shell /usr/bin/false 2>&1 \
            | grep -v -E 'Creating user record|Setting up home directory|done' \
            >&2; then
        :
    fi
    unset one_shot_password

    if ! id devbox-agent >/dev/null 2>&1; then
        printf 'host_platform::ensure_agent_user: sysadminctl did not create devbox-agent\n' >&2
        return 1
    fi
}
