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
  5. Checks Docker availability (never installs automatically)
  6. Installs 'devbox' command to /usr/local/bin

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

# --- SSH agent configuration -------------------------------------------------

configure_ssh_agent() {
    info "Configuring SSH agent..."

    # Determine login shell profile (runs once per session, not managed by dotfiles)
    local rc_file
    case "$(basename "${SHELL:-/bin/bash}")" in
        zsh)  rc_file="$HOME/.zprofile" ;;
        bash) rc_file="$HOME/.bash_profile" ;;
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
                keychain_cmd='eval $(keychain --eval --quiet --agents ssh --inherit any)'
            else
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
        msg "  4. Check Docker availability"
        msg "  5. Install 'devbox' command to $SYMLINK_PATH"
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
    install_command

    echo ""
    check_docker
    add_docker_group

    print_summary
}

main
