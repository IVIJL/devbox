#!/bin/bash
set -euo pipefail
trap 'printf "\033[1;31m==> ERROR: Script failed at line %s (exit code %s)\033[0m\n" "$LINENO" "$?"' ERR

# =============================================================================
# Devbox Installer
# =============================================================================
# Installs prerequisites and sets up devbox development environment.
#
# Recommended usage:
#   curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/IVIJL/devbox/main/install.sh -o install.sh
#   less install.sh
#   bash install.sh
#
# One-liner:
#   curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/IVIJL/devbox/main/install.sh | bash -s -- --yes
# =============================================================================

DEVBOX_REPO="https://github.com/IVIJL/devbox.git"
DEVBOX_DIR="${HOME}/.local/share/devbox"
SYMLINK_PATH="/usr/local/bin/devbox"

# mkcert version printed in the install summary. The authoritative pin lives
# in scripts/install-mkcert.sh (which also holds the SHA-256 table); this
# constant is display-only. A drift here would just print a stale version
# string — the version gate at runtime is owned by lib/mkcert.sh's
# _mkcert::probe and stays correct regardless.
MKCERT_VERSION="1.4.4"

AUTO_YES=false
OS=""
PM=""
NEED_RELOGIN=false

# Tracking what was done
declare -a INSTALLED=()
declare -a SKIPPED=()
declare -a CONFIGURED=()

# --- Helpers -----------------------------------------------------------------

msg()     { printf '  %s\n' "$*"; }
info()    { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
success() { printf '\033[1;32m==> %s\033[0m\n' "$*"; }
warn()    { printf '\033[1;33m==> WARNING: %s\033[0m\n' "$*"; }
error()   { printf '\033[1;31m==> ERROR: %s\033[0m\n' "$*"; exit 1; }

confirm() {
    if $AUTO_YES; then return 0; fi
    printf '\033[1;33m==> %s [y/N] \033[0m' "$1"
    read -r answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

has() { command -v "$1" &>/dev/null; }

is_wsl2() { grep -qi microsoft /proc/version 2>/dev/null; }

# Docker state after check_docker(): "running", "installed", "desktop", "missing"
DOCKER_STATE="missing"

# --- Argument parsing --------------------------------------------------------

usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS]

Install devbox and its prerequisites.

Options:
  --yes, -y    Skip all confirmation prompts (required when piped)
  --help, -h   Show this help message

What this script does:
  1. Installs git and keychain (if missing)
  2. Configures SSH agent via keychain (no key scanning)
  3. Adds AddKeysToAgent to ~/.ssh/config
  4. Clones devbox to ~/.local/share/devbox
  5. Installs mkcert (for HTTPS dev certs; CA install runs later via dns-install)
  6. Checks Docker availability (never installs automatically)
  7. Installs 'devbox' command to /usr/local/bin

This script NEVER accesses or scans your private SSH keys.
EOF
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        --yes|-y) AUTO_YES=true ;;
        --help|-h) usage ;;
        *) error "Unknown option: $arg (use --help for usage)" ;;
    esac
done

# --- Pipe detection ----------------------------------------------------------

if [ ! -t 0 ] && ! $AUTO_YES; then
    cat <<'EOF'

  This script is being piped but --yes was not passed.

  For safety, please either:

  1. Download and review first (recommended):
     curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/IVIJL/devbox/main/install.sh -o install.sh
     less install.sh
     bash install.sh

  2. Or pass --yes to accept all prompts:
     curl ... | bash -s -- --yes

EOF
    exit 1
fi

# --- OS / package manager detection ------------------------------------------

detect_os() {
    info "Detecting operating system..."

    case "$(uname -s)" in
        Darwin)
            OS="macos"
            PM="brew"
            if ! has brew; then
                error "Homebrew is required on macOS. Install from https://brew.sh"
            fi
            msg "macOS detected (Homebrew)"
            return
            ;;
        Linux) ;;
        *) error "Unsupported OS: $(uname -s)" ;;
    esac

    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID:-}" in
            ubuntu|debian|pop|mint|raspbian|linuxmint) PM="apt-get" ;;
            fedora|rhel|centos|rocky|almalinux)        PM="dnf" ;;
            arch|manjaro|endeavouros)                   PM="pacman" ;;
            opensuse*|sles)                             PM="zypper" ;;
            alpine)                                     PM="apk" ;;
        esac
    fi

    # Fallback: detect by available command
    if [ -z "$PM" ]; then
        for pm in apt-get dnf pacman zypper apk; do
            if has "$pm"; then PM="$pm"; break; fi
        done
    fi

    [ -n "$PM" ] || error "Could not detect package manager. Install git, Docker, and keychain manually."
    OS="linux"
    msg "Linux detected (${PM})"
}

# --- Package installation helpers --------------------------------------------

pkg_install() {
    local pkg="$1"
    case "$PM" in
        brew)    brew install "$pkg" ;;
        apt-get) sudo apt-get install -y "$pkg" ;;
        dnf)     sudo dnf install -y "$pkg" ;;
        pacman)  sudo pacman -S --noconfirm "$pkg" ;;
        zypper)  sudo zypper install -y "$pkg" ;;
        apk)     sudo apk add "$pkg" ;;
    esac
}

pkg_update() {
    case "$PM" in
        apt-get) sudo apt-get update ;;
        dnf)     ;; # dnf auto-refreshes
        pacman)  ;; # pacman -Sy without -u is unsafe; pacman -S handles it
        zypper)  sudo zypper refresh ;;
        apk)     sudo apk update ;;
        brew)    brew update ;;
    esac
}

# --- Install prerequisites ---------------------------------------------------

install_git() {
    info "Checking git..."
    if has git; then
        SKIPPED+=("git ($(git --version))")
        return
    fi
    msg "Installing git..."
    pkg_install git
    INSTALLED+=("git")
}

install_docker_ce() {
    # Linux: install Docker CE from official repo
    msg "Installing Docker CE from official repository..."

    # shellcheck disable=SC1091
    local docker_id=""
    if [ "$PM" = "apt-get" ]; then
        # shellcheck disable=SC1091  # /etc/os-release is a system file, not available to shellcheck
        docker_id=$(. /etc/os-release && echo "$ID")
        [[ "$docker_id" =~ ^[a-z]+$ ]] || error "Invalid OS ID for Docker repo: $docker_id"
    fi

    case "$PM" in
        apt-get)
            sudo apt-get install -y ca-certificates curl gnupg
            sudo install -m 0755 -d /etc/apt/keyrings
            if [ ! -f /etc/apt/keyrings/docker.asc ]; then
                curl -fsSL "https://download.docker.com/linux/${docker_id}/gpg" | sudo tee /etc/apt/keyrings/docker.asc > /dev/null
                sudo chmod a+r /etc/apt/keyrings/docker.asc
                # Verify Docker GPG key fingerprint
                if has gpg; then
                    local fingerprint
                    fingerprint=$(gpg --dry-run --quiet --import --import-options import-show /etc/apt/keyrings/docker.asc 2>/dev/null | grep -oE '[0-9A-F]{40}' | head -1)
                    if [ "$fingerprint" != "9DC858229FC7DD38854AE2D88D81803C0EBFCD88" ]; then
                        sudo rm -f /etc/apt/keyrings/docker.asc
                        error "Docker GPG key fingerprint mismatch! Expected 9DC8...CD88, got ${fingerprint:-none}"
                    fi
                    msg "Docker GPG key fingerprint verified."
                else
                    warn "gpg not available, skipping Docker GPG key fingerprint verification."
                fi
            fi
            # shellcheck disable=SC1091
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${docker_id} $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
                sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            sudo apt-get update
            sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        dnf)
            sudo dnf install -y dnf-plugins-core
            sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo 2>/dev/null || \
                sudo dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo
            sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        pacman)
            sudo pacman -S --noconfirm docker docker-buildx docker-compose
            ;;
        zypper)
            sudo zypper install -y docker docker-buildx docker-compose
            ;;
        apk)
            sudo apk add docker docker-cli-buildx docker-cli-compose
            ;;
    esac

    # Enable and start Docker
    if has systemctl; then
        sudo systemctl enable docker 2>/dev/null || true
        sudo systemctl start docker 2>/dev/null || true
    fi

    INSTALLED+=("Docker CE")
    DOCKER_STATE="running"
}

check_docker() {
    info "Checking Docker..."

    # 1. Docker binary exists and daemon responds
    if has docker && docker info &>/dev/null 2>&1; then
        DOCKER_STATE="running"
        SKIPPED+=("Docker ($(docker --version 2>/dev/null | head -c 60))")
        return
    fi

    # 2. Docker binary exists but daemon not responding
    if has docker; then
        DOCKER_STATE="installed"
        warn "Docker is installed but not running."
        if is_wsl2; then
            msg "Start Docker Desktop on Windows, or start the Docker daemon."
        else
            msg "Start the Docker daemon (e.g. sudo systemctl start docker)."
        fi
        SKIPPED+=("Docker (installed but not running)")
        return
    fi

    # 3. Docker Desktop detected but binary not available
    if is_wsl2 && [ -d "/mnt/c/Program Files/Docker" ]; then
        DOCKER_STATE="desktop"
        warn "Docker Desktop is installed on Windows but not available in WSL2."
        msg "Start Docker Desktop and enable WSL2 integration in Settings."
        SKIPPED+=("Docker (Desktop installed, not available in WSL2)")
        return
    fi

    if [ "$OS" = "macos" ] && [ -d "/Applications/Docker.app" ]; then
        DOCKER_STATE="desktop"
        warn "Docker Desktop is installed but not running."
        msg "Start Docker Desktop from Applications."
        SKIPPED+=("Docker (Desktop installed, not running)")
        return
    fi

    # 4. Docker not found at all
    DOCKER_STATE="missing"

    if [ "$OS" = "macos" ]; then
        warn "Docker is not installed."
        msg "Install Docker via one of:"
        msg "  - Docker Desktop: https://www.docker.com/products/docker-desktop/"
        msg "  - OrbStack:       https://orbstack.dev"
        msg "  - Colima:         brew install colima docker docker-compose"
        SKIPPED+=("Docker (not installed)")
        return
    fi

    if is_wsl2; then
        warn "Docker is not installed."
        msg "Recommended: Install Docker Desktop for Windows with WSL2 integration."
        msg "  https://www.docker.com/products/docker-desktop/"
        msg ""
        if confirm "Install Docker CE inside WSL2 instead?"; then
            install_docker_ce
        else
            SKIPPED+=("Docker (not installed)")
        fi
        return
    fi

    # Native Linux
    if $AUTO_YES; then
        install_docker_ce
    elif confirm "Install Docker CE?"; then
        install_docker_ce
    else
        SKIPPED+=("Docker (not installed)")
    fi
}

add_docker_group() {
    if [ "$OS" != "linux" ]; then return; fi
    if ! has docker; then return; fi
    if id -nG "$USER" 2>/dev/null | grep -qw docker; then
        SKIPPED+=("docker group (already member)")
        return
    fi
    if ! getent group docker &>/dev/null; then
        sudo groupadd docker 2>/dev/null || true
    fi
    info "Adding $USER to docker group..."
    sudo usermod -aG docker "$USER"
    CONFIGURED+=("docker group membership")
    NEED_RELOGIN=true
}

install_keychain() {
    info "Checking keychain..."
    if has keychain; then
        SKIPPED+=("keychain (already installed)")
        return
    fi
    msg "Installing keychain..."
    pkg_install keychain
    INSTALLED+=("keychain")
}

# --- mkcert ------------------------------------------------------------------
# mkcert backs the HTTPS-by-default rollout (ADR 0008). The actual fetch +
# SHA-256 verify + binary placement lives in scripts/install-mkcert.sh so the
# HTTPS upgrade orchestration (`_dns::install_ca` and `_devbox::run_https_upgrade`)
# can call the same provisioner without dragging in install.sh's repo-clone
# and symlink-replace side effects — see install-mkcert.sh's header for why
# that split exists. install.sh keeps `install_mkcert` as a thin wrapper so
# the summary still tracks INSTALLED/SKIPPED for the user.

install_mkcert() {
    info "Checking mkcert..."

    local provisioner="$DEVBOX_DIR/scripts/install-mkcert.sh"
    if [ ! -x "$provisioner" ]; then
        warn "scripts/install-mkcert.sh missing or non-executable; skipping mkcert."
        SKIPPED+=("mkcert (provisioner script missing)")
        return
    fi

    # `--with-nss` lets the provisioner install libnss3-tools (or equivalent)
    # on Linux when certutil is absent — without it `mkcert -install` warns
    # and silently skips Firefox/Chrome trust. macOS uses the Keychain so
    # the flag is a no-op there; the provisioner short-circuits before any
    # sudo prompt.
    local extra_args=()
    [ "$OS" = "linux" ] && extra_args+=("--with-nss")

    # Capture the resolved binary path so the summary line is precise.
    # The provisioner prints exactly one stdout line (the binary path) on
    # success; diagnostics land on stderr and pass straight through to the
    # terminal so the user sees download progress live.
    local resolved=""
    if resolved="$("$provisioner" "${extra_args[@]}")"; then
        INSTALLED+=("mkcert ($resolved)")
    else
        SKIPPED+=("mkcert (install failed; see warnings above)")
    fi
}

# --- Allow-for host state (ADR 0009) -----------------------------------------
# Provisions /var/log/devbox/allow-for/ (root-owned, mounted into containers)
# and, on WSL2, the toast notification AppId. install.sh is the canonical
# creation path; `devbox update` runs the same provisioner as a self-heal
# for existing installs that predate ADR 0009. The script is idempotent and
# only fires sudo when the dir is missing or has wrong perms.

setup_allow_for_state() {
    info "Configuring allow-for host state..."

    local provisioner="$DEVBOX_DIR/scripts/ensure-allow-for-host-state.sh"
    if [ ! -x "$provisioner" ]; then
        warn "scripts/ensure-allow-for-host-state.sh missing or non-executable; skipping."
        SKIPPED+=("allow-for host state (provisioner script missing)")
        return
    fi

    if "$provisioner"; then
        CONFIGURED+=("allow-for host state (/var/log/devbox/allow-for + WSL toast AppId)")
    else
        SKIPPED+=("allow-for host state (setup failed; see warnings above)")
    fi
}

# --- Agent-browser OS user (ADR 0010) ----------------------------------------
# Provisions the `devbox-agent` host OS user that Host agent Chrome runs
# under. The OS-identity separation is the primary defence the agent-browser
# feature buys (see ADR 0010 § Actor 1) — without it, Chrome with
# --user-data-dir alone could still file:// the developer's home or write
# autostart payloads as the real user. Idempotent: a second run is a no-op
# when the user already exists. Sudo prompts only on first install
# (Linux/WSL2: useradd; macOS: sysadminctl).

setup_agent_user() {
    info "Configuring devbox-agent OS user (agent-browser feature)..."

    local lib="$DEVBOX_DIR/lib/host-platform.sh"
    if [ ! -r "$lib" ]; then
        warn "lib/host-platform.sh missing; skipping devbox-agent user creation."
        SKIPPED+=("devbox-agent user (host-platform.sh missing)")
        return
    fi

    local user_created=false
    if id devbox-agent >/dev/null 2>&1; then
        SKIPPED+=("devbox-agent user (already exists)")
        user_created=true
    else
        # shellcheck source=lib/host-platform.sh disable=SC1091
        if ( . "$lib" && host_platform::ensure_agent_user ); then
            CONFIGURED+=("devbox-agent user (created)")
            user_created=true
        else
            warn "Failed to create devbox-agent user — devbox agent-browser commands will not work until this is fixed."
            SKIPPED+=("devbox-agent user (creation failed; see warnings above)")
        fi
    fi

    if [ "$user_created" != true ]; then
        return
    fi

    # Delegate group provisioning + invoker membership to the dedicated
    # host-state script — the same one `devbox update` self-heals
    # through, so install-time and upgrade-time paths stay in lockstep.
    # ADR 0010 documents the group-read path for the developer; without
    # it the forensic output (netlog, proxy log, summary) the CLI
    # advertises is locked behind sudo.
    local host_state_script="$DEVBOX_DIR/scripts/ensure-agent-browser-host-state.sh"
    if [ ! -x "$host_state_script" ]; then
        warn "scripts/ensure-agent-browser-host-state.sh missing or non-executable; group provisioning skipped."
        SKIPPED+=("devbox-agent group provisioning (script missing)")
        return
    fi

    if "$host_state_script"; then
        CONFIGURED+=("devbox-agent group provisioned ($USER membership configured)")
        if ! id -nG "$USER" 2>/dev/null | tr ' ' '\n' | grep -qx devbox-agent; then
            warn "Re-login (or run 'newgrp devbox-agent') so the new group membership takes effect in your current shell."
        fi
    else
        warn "Failed to provision devbox-agent group state — agent-browser artefacts will not be readable without sudo."
        SKIPPED+=("devbox-agent group provisioning (failed; see warnings above)")
    fi
}

# --- Agent-browser Python helpers (ADR 0010) ---------------------------------
# Delegates to scripts/ensure-agent-browser-helpers.sh — the same script
# `devbox update` self-heals existing installs through, so install-time
# and upgrade-time paths stay in lockstep.

stage_agent_browser_helpers() {
    info "Staging agent-browser Python helpers..."

    local provisioner="$DEVBOX_DIR/scripts/ensure-agent-browser-helpers.sh"
    if [ ! -x "$provisioner" ]; then
        warn "scripts/ensure-agent-browser-helpers.sh missing or non-executable; skipping."
        SKIPPED+=("agent-browser helpers (provisioner missing)")
        return
    fi

    if "$provisioner"; then
        CONFIGURED+=("agent-browser helpers staged (/usr/local/lib/devbox/agent-browser)")
    else
        warn "Failed to stage agent-browser helpers — devbox agent-browser will not start."
        SKIPPED+=("agent-browser helpers (stage failed; see warnings above)")
    fi
}

# --- Upstream agent-browser skill (ADR 0011) ---------------------------------
# Delegates to scripts/ensure-upstream-agent-browser-skill.sh — the same
# script `devbox update` self-heals existing installs through, so install-time
# and upgrade-time paths stay in lockstep. The helper invokes
# `npx skills add vercel-labs/agent-browser …` headlessly. Soft failures
# (npx missing, network down) surface as install warnings instead of aborting
# the install.

setup_upstream_agent_browser_skill() {
    info "Installing upstream vercel-labs/agent-browser skill..."

    local provisioner="$DEVBOX_DIR/scripts/ensure-upstream-agent-browser-skill.sh"
    if [ ! -x "$provisioner" ]; then
        warn "scripts/ensure-upstream-agent-browser-skill.sh missing or non-executable; skipping."
        SKIPPED+=("upstream agent-browser skill (provisioner script missing)")
        return
    fi

    if "$provisioner"; then
        CONFIGURED+=("upstream agent-browser skill (~/.agents/skills/agent-browser)")
    else
        warn "Failed to install upstream agent-browser skill — see warnings above."
        SKIPPED+=("upstream agent-browser skill (install failed; see warnings above)")
    fi
}

# --- Agent-browser allowlist example file (ADR 0010) -------------------------
# Ships a documented `.example` copy of the agent-browser allowlist so the
# user has a template to copy when they decide to enable the feature. We
# never overwrite the real `agent-browser-allowed-domains.conf` even if
# present — the user's edits are sacred. Idempotent.

setup_agent_allowlist_example() {
    info "Installing agent-browser allowlist example..."

    local cfg_dir="${XDG_CONFIG_HOME:-$HOME/.config}/devbox"
    local example="$cfg_dir/agent-browser-allowed-domains.conf.example"

    mkdir -p "$cfg_dir"
    cat > "$example" <<'EOF'
# devbox agent-browser default-mode allowlist
# One domain pattern per line. `#` lines are comments.
# Glob `*.example.com` matches all subdomains.
#
# Examples:
# *.github.com
# api.openai.com
# registry.npmjs.org
EOF
    CONFIGURED+=("agent-browser allowlist example ($example)")
}

# --- Devbox agent skill (ADR 0011) -------------------------------------------
# Delegates to scripts/ensure-devbox-skill.sh — the same script
# `devbox update` self-heals existing installs through, so install-time
# and upgrade-time paths stay in lockstep. Seeds the host-shared
# 'devbox' skill at ~/.agents/skills/devbox/ + per-agent symlinks for
# Claude Code and Codex so every Container picks it up via the existing
# host bind mounts (ADR 0002).

setup_devbox_skill() {
    info "Installing devbox agent skill..."

    local provisioner="$DEVBOX_DIR/scripts/ensure-devbox-skill.sh"
    if [ ! -x "$provisioner" ]; then
        warn "scripts/ensure-devbox-skill.sh missing or non-executable; skipping."
        SKIPPED+=("devbox agent skill (provisioner missing)")
        return
    fi

    if "$provisioner"; then
        CONFIGURED+=("devbox agent skill (~/.agents/skills/devbox + Claude/Codex symlinks)")
    else
        warn "Failed to seed devbox agent skill — agents will lack devbox-aware context."
        SKIPPED+=("devbox agent skill (setup failed; see warnings above)")
    fi
}

# --- MCP onboarding (ADR 0013) -----------------------------------------------
# Delegates to scripts/ensure-mcp-onboarding.sh — the same hook the
# `devbox update` self-heal chain calls, so install-time and upgrade-time
# paths stay in lockstep. On a fresh interactive install it offers to scan
# existing Claude Code / Codex MCP servers for devbox import; non-interactive
# installs print a follow-up command instead (never a prompt or picker).

setup_mcp_onboarding() {
    info "Checking MCP onboarding..."

    local hook="$DEVBOX_DIR/scripts/ensure-mcp-onboarding.sh"
    if [ ! -x "$hook" ]; then
        warn "scripts/ensure-mcp-onboarding.sh missing or non-executable; skipping."
        SKIPPED+=("MCP onboarding (hook missing)")
        return
    fi

    # A piped/`--yes` install has no usable TTY for the wizard; force the
    # non-interactive branch so it prints the follow-up command instead of
    # blocking on a prompt. An interactive install runs the offer directly.
    local hook_args=()
    if $AUTO_YES || [ ! -t 0 ]; then
        hook_args+=("--non-interactive")
    fi

    if "$hook" "${hook_args[@]}"; then
        CONFIGURED+=("MCP onboarding (run 'devbox mcp import' to discover servers)")
    else
        warn "MCP onboarding check failed — run 'devbox mcp import' manually later."
        SKIPPED+=("MCP onboarding (check failed; see warnings above)")
    fi
}

# --- SSH agent configuration -------------------------------------------------

configure_ssh_agent() {
    info "Configuring SSH agent..."

    # Determine login shell profile (runs once per session, not managed by dotfiles)
    # IMPORTANT: For bash, prefer existing ~/.profile over creating ~/.bash_profile.
    # Bash reads ~/.bash_profile first and STOPS — creating it shadows ~/.profile,
    # breaking any existing user/system configuration there.
    local rc_file
    case "$(basename "${SHELL:-/bin/bash}")" in
        zsh)  rc_file="$HOME/.zprofile" ;;
        bash)
            if [ -f "$HOME/.bash_profile" ]; then
                rc_file="$HOME/.bash_profile"
            else
                rc_file="$HOME/.profile"
            fi
            ;;
        *)    rc_file="$HOME/.profile" ;;
    esac

    local marker="# Devbox: persistent SSH agent via keychain"

    if has keychain; then
        if grep -qF "$marker" "$rc_file" 2>/dev/null; then
            SKIPPED+=("keychain in $rc_file (already configured)")
        else
            msg "Adding keychain eval to $rc_file..."
            local keychain_cmd
            if [ "$OS" = "macos" ]; then
                # shellcheck disable=SC2016  # intentionally writing literal $() into shell rc file
                keychain_cmd='eval $(keychain --eval --quiet --agents ssh --inherit any)'
            else
                # shellcheck disable=SC2016
                keychain_cmd='eval $(keychain --eval --quiet --agents ssh)'
            fi
            printf '\n%s\n%s\n' "$marker" "$keychain_cmd" >> "$rc_file"
            CONFIGURED+=("keychain in $rc_file")
        fi
    else
        warn "keychain not found, skipping shell RC configuration"
    fi

    # SSH config: AddKeysToAgent
    local ssh_dir="$HOME/.ssh"
    local ssh_config="$ssh_dir/config"
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"

    if grep -qF "AddKeysToAgent" "$ssh_config" 2>/dev/null; then
        SKIPPED+=("AddKeysToAgent in ssh config (already set)")
    else
        msg "Adding AddKeysToAgent to $ssh_config..."
        local ssh_block
        ssh_block="$(cat <<'SSH_EOF'
# Devbox: auto-add keys to agent on first SSH use
Host *
    AddKeysToAgent yes
    IgnoreUnknown UseKeychain
    UseKeychain yes

SSH_EOF
)"
        if [ -f "$ssh_config" ]; then
            # Prepend to existing config
            local tmp
            tmp=$(mktemp "$ssh_dir/config.XXXXXX")
            printf '%s\n' "$ssh_block" | cat - "$ssh_config" > "$tmp"
            mv "$tmp" "$ssh_config"
        else
            printf '%s\n' "$ssh_block" > "$ssh_config"
        fi
        chmod 600 "$ssh_config"
        CONFIGURED+=("AddKeysToAgent in $ssh_config")
    fi
}

# --- Claude Code setup-token ------------------------------------------------

setup_claude_token() {
    info "Checking Claude Code token..."

    local token_file="$HOME/.config/devbox/claude-token"

    if [ -f "$token_file" ]; then
        SKIPPED+=("Claude token (already configured)")
        return
    fi

    if [ -f "$HOME/.claude/.credentials.json" ]; then
        SKIPPED+=("Claude token (host OAuth credentials present, will be symlinked)")
        return
    fi

    if ! has claude; then
        SKIPPED+=("Claude token (claude not installed on host)")
        return
    fi

    msg "Run 'devbox claude-token' after install to set up a long-lived token."
    msg "This avoids daily re-login when using Claude Code in containers."
    SKIPPED+=("Claude token (run 'devbox claude-token' to set up)")
}

# --- Shell completion --------------------------------------------------------
#
# Two parallel completion files live in completions/:
#   _devbox       — zsh (`#compdef devbox`, native fpath-installed)
#   devbox.bash   — bash (`complete -F _devbox devbox`, sourced from .bashrc
#                   or dropped into a system bash-completion dir)
#
# The install routine routes by $SHELL: zsh users get fpath wiring (existing
# behaviour); bash users get the bash file sourced from .bashrc. Anything
# else is skipped with a notice.

# Install zsh completion via fpath lookup. Extracted so setup_completions can
# stay a thin dispatcher.
_install_zsh_completion() {
    local src="$DEVBOX_DIR/completions/_devbox"
    if [ ! -f "$src" ]; then
        SKIPPED+=("zsh completion (completion file not found in repo)")
        return
    fi

    # Ask zsh for its current fpath entries
    local fpath_dirs
    fpath_dirs=$(zsh -c 'echo $fpath' 2>/dev/null | tr ' ' '\n')

    # Priority 1: writable fpath dir — no sudo, no .zshrc changes
    local dest_dir=""
    while IFS= read -r dir; do
        [ -d "$dir" ] || continue
        case "$dir" in "$DEVBOX_DIR"*) continue ;; esac  # skip self
        if [ -w "$dir" ]; then
            dest_dir="$dir"
            break
        fi
    done <<< "$fpath_dirs"

    if [ -n "$dest_dir" ]; then
        cp "$src" "$dest_dir/_devbox"
        CONFIGURED+=("zsh completion -> $dest_dir/_devbox")
        return
    fi

    # Priority 2: fpath dir via sudo — no .zshrc changes
    while IFS= read -r dir; do
        [ -d "$dir" ] || continue
        case "$dir" in "$DEVBOX_DIR"*) continue ;; esac
        if sudo cp "$src" "$dir/_devbox" 2>/dev/null; then
            CONFIGURED+=("zsh completion -> $dir/_devbox (via sudo)")
            return
        fi
    done <<< "$fpath_dirs"

    # Priority 3: fallback ~/.zsh/completions — only touches .zshrc when no fpath exists
    dest_dir="$HOME/.zsh/completions"
    mkdir -p "$dest_dir"
    cp "$src" "$dest_dir/_devbox"

    local zshrc="$HOME/.zshrc"
    local marker="# Devbox: zsh completion fpath"
    if grep -qF "$marker" "$zshrc" 2>/dev/null; then
        SKIPPED+=("zsh fpath in $zshrc (already configured)")
    elif grep -q 'compinit' "$zshrc" 2>/dev/null; then
        # Insert fpath line before the first compinit occurrence
        sed -i "/compinit/i $marker\nfpath=(~\/.zsh\/completions \$fpath)" "$zshrc"
        CONFIGURED+=("zsh fpath in $zshrc (added before compinit)")
    else
        # shellcheck disable=SC2016  # $fpath is a zsh variable, intentionally unexpanded
        printf '\n%s\nfpath=(~/.zsh/completions $fpath)\n' "$marker" >> "$zshrc"
        CONFIGURED+=("zsh fpath in $zshrc")
    fi
    CONFIGURED+=("zsh completion -> $dest_dir/_devbox")
}

# Install bash completion. The source file is self-contained: it can be
# sourced directly from .bashrc (no system completion dir required), which
# is the simplest path for a single-binary CLI like devbox.
#
# Strategy: idempotent .bashrc edit gated by a marker line, similar to the
# zsh fpath path above. We don't try to write into /etc or
# /usr/local/etc/bash_completion.d/ because that needs sudo for what amounts
# to a per-user CLI.
_install_bash_completion() {
    local src="$DEVBOX_DIR/completions/devbox.bash"
    if [ ! -f "$src" ]; then
        SKIPPED+=("bash completion (completion file not found in repo)")
        return
    fi

    local bashrc="$HOME/.bashrc"
    local marker="# Devbox: bash completion"
    local source_line="source \"$src\""

    if grep -qF "$marker" "$bashrc" 2>/dev/null; then
        SKIPPED+=("bash completion in $bashrc (already configured)")
        return
    fi

    printf '\n%s\n%s\n' "$marker" "$source_line" >> "$bashrc"
    CONFIGURED+=("bash completion in $bashrc")
}

setup_completions() {
    local shell_name
    shell_name="$(basename "${SHELL:-/bin/bash}")"
    case "$shell_name" in
        zsh)  _install_zsh_completion ;;
        bash) _install_bash_completion ;;
        *)
            SKIPPED+=("shell completion (shell is $shell_name, not zsh or bash)")
            ;;
    esac
}

# --- Clone / update devbox repo ---------------------------------------------

setup_devbox_repo() {
    info "Setting up devbox repository..."

    if [ -d "$DEVBOX_DIR" ]; then
        if [ -d "$DEVBOX_DIR/.git" ]; then
            local current_remote
            current_remote=$(git -C "$DEVBOX_DIR" remote get-url origin 2>/dev/null || echo "")
            if [ "$current_remote" = "$DEVBOX_REPO" ]; then
                msg "Updating existing devbox installation..."
                git -C "$DEVBOX_DIR" pull --ff-only
                SKIPPED+=("devbox repo (updated)")
                return
            else
                error "$DEVBOX_DIR exists but has different remote: $current_remote (expected $DEVBOX_REPO)"
            fi
        else
            error "$DEVBOX_DIR exists but is not a git repository"
        fi
    fi

    msg "Cloning devbox to $DEVBOX_DIR..."
    mkdir -p "$(dirname "$DEVBOX_DIR")"
    git clone "$DEVBOX_REPO" "$DEVBOX_DIR"
    INSTALLED+=("devbox repo")
}

# --- Install devbox command --------------------------------------------------

install_command() {
    info "Installing devbox command..."

    local target="$DEVBOX_DIR/docker-run.sh"

    if [ ! -f "$target" ]; then
        warn "$target not found, skipping symlink."
        return
    fi

    chmod +x "$target"

    if [ -L "$SYMLINK_PATH" ]; then
        local current_target
        current_target=$(readlink "$SYMLINK_PATH")
        if [ "$current_target" = "$target" ]; then
            SKIPPED+=("devbox command (already linked)")
            return
        fi
        warn "$SYMLINK_PATH currently points to $current_target"
        if ! confirm "Replace symlink to point to $target?"; then
            SKIPPED+=("devbox command (kept existing)")
            return
        fi
    elif [ -e "$SYMLINK_PATH" ]; then
        warn "$SYMLINK_PATH exists and is not a symlink"
        if ! confirm "Replace $SYMLINK_PATH?"; then
            SKIPPED+=("devbox command (kept existing)")
            return
        fi
    fi

    # Try without sudo first, fall back to sudo
    if [ -w "$(dirname "$SYMLINK_PATH")" ]; then
        ln -sf "$target" "$SYMLINK_PATH"
    else
        sudo ln -sf "$target" "$SYMLINK_PATH"
    fi
    CONFIGURED+=("devbox command -> $target")
}

# --- Summary -----------------------------------------------------------------

print_summary() {
    echo ""
    success "Devbox installation complete!"
    echo ""

    if [ ${#INSTALLED[@]} -gt 0 ]; then
        msg "Installed:"
        for item in "${INSTALLED[@]}"; do msg "  + $item"; done
    fi

    if [ ${#CONFIGURED[@]} -gt 0 ]; then
        msg "Configured:"
        for item in "${CONFIGURED[@]}"; do msg "  ~ $item"; done
    fi

    if [ ${#SKIPPED[@]} -gt 0 ]; then
        msg "Skipped:"
        for item in "${SKIPPED[@]}"; do msg "  - $item"; done
    fi

    if $NEED_RELOGIN; then
        echo ""
        warn "You were added to the 'docker' group."
        msg "Log out and back in (or run: newgrp docker) for this to take effect."
    fi

    echo ""
    msg "SSH keys will be added to the agent automatically on first use"
    msg "(you'll be prompted for your passphrase once per session)."

    # --- Next steps ---
    echo ""
    info "Next steps:"

    local step=1

    case "$DOCKER_STATE" in
        running)
            ;;
        installed)
            msg "  ${step}. Start Docker daemon"
            if is_wsl2; then
                msg "     Start Docker Desktop on Windows, or: sudo systemctl start docker"
            elif [ "$OS" = "macos" ]; then
                msg "     Open Docker Desktop from Applications"
            else
                msg "     sudo systemctl start docker"
            fi
            step=$((step + 1))
            ;;
        desktop)
            msg "  ${step}. Start Docker Desktop"
            if is_wsl2; then
                msg "     Start Docker Desktop on Windows and enable WSL2 integration"
            else
                msg "     Open Docker Desktop from Applications"
            fi
            step=$((step + 1))
            ;;
        missing)
            msg "  ${step}. Install Docker"
            if [ "$OS" = "macos" ]; then
                msg "     Docker Desktop: https://www.docker.com/products/docker-desktop/"
                msg "     OrbStack:       https://orbstack.dev"
            elif is_wsl2; then
                msg "     Docker Desktop for Windows: https://www.docker.com/products/docker-desktop/"
                msg "     Or install Docker CE: see https://docs.docker.com/engine/install/"
            else
                msg "     See https://docs.docker.com/engine/install/"
            fi
            step=$((step + 1))
            ;;
    esac

    msg "  ${step}. Build the image:  devbox build"
    step=$((step + 1))

    msg "  ${step}. Set your API key: export ANTHROPIC_API_KEY=sk-ant-..."
    step=$((step + 1))

    msg "  ${step}. Run devbox:       devbox"
}

# --- Main --------------------------------------------------------------------

main() {
    echo ""
    info "Devbox Installer"
    echo ""

    detect_os
    echo ""

    if ! $AUTO_YES; then
        msg "This script will:"
        msg "  1. Install git and keychain (if missing)"
        msg "  2. Configure SSH agent via keychain"
        msg "  3. Clone devbox to $DEVBOX_DIR"
        msg "  4. Install mkcert v$MKCERT_VERSION (HTTPS dev certs; CA install deferred to dns-install)"
        msg "  5. Set up /var/log/devbox/allow-for (root-owned harvest log dir; sudo prompt)"
        msg "  6. Create devbox-agent OS user + add $USER to that group (agent-browser feature; sudo prompt)"
        msg "  7. Stage agent-browser Python helpers to /usr/local/lib/devbox (sudo prompt)"
        msg "  8. Install upstream vercel-labs/agent-browser skill via 'npx skills add' (network)"
        msg "  9. Install agent-browser allowlist example to \$HOME/.config/devbox"
        msg " 10. Install 'devbox' agent skill to \$HOME/.agents/skills/devbox (+ Claude/Codex symlinks)"
        msg " 11. Offer MCP onboarding (scan existing Claude Code / Codex MCP servers for devbox import)"
        msg " 12. Install 'devbox' command to $SYMLINK_PATH"
        msg " 13. Optionally generate Claude Code token for containers"
        msg " 14. Check Docker availability"
        echo ""
        if ! confirm "Continue?"; then
            msg "Aborted."
            exit 0
        fi
        echo ""
    fi

    pkg_update

    install_git
    install_keychain

    echo ""
    configure_ssh_agent

    echo ""
    setup_devbox_repo

    echo ""
    install_mkcert

    echo ""
    setup_allow_for_state

    echo ""
    setup_agent_user

    echo ""
    stage_agent_browser_helpers

    echo ""
    setup_upstream_agent_browser_skill

    echo ""
    setup_agent_allowlist_example

    echo ""
    setup_devbox_skill

    echo ""
    setup_mcp_onboarding

    echo ""
    install_command

    echo ""
    setup_completions

    echo ""
    setup_claude_token

    echo ""
    check_docker
    add_docker_group

    print_summary
}

main
