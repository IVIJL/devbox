FROM node:20

ARG TZ=Europe/Prague
ENV TZ="$TZ"

ARG CLAUDE_CODE_VERSION=latest

# =============================================================================
# Layer 1: APT packages (Claude Code base + user tools)
# =============================================================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Claude Code packages
    less git procps sudo fzf zsh man-db unzip gnupg2 gh \
    iptables ipset iproute2 dnsutils aggregate jq nano vim \
    # User packages
    ncdu mc nala libfuse2 xauth xclip ripgrep fd-find \
    build-essential zsh-autosuggestions zsh-syntax-highlighting \
    grc curl wget fuse-overlayfs \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && ln -s "$(which fdfind)" /usr/local/bin/fd

# Docker CE (for Docker-in-Docker)
RUN curl -fsSL https://get.docker.com | sh && \
    usermod -aG docker node

# =============================================================================
# Layer 2: Binary installs (root)
# =============================================================================

# git-delta
ARG GIT_DELTA_VERSION=0.18.2
RUN ARCH=$(dpkg --print-architecture) && \
    wget -q "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
    dpkg -i "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
    rm "git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb"

# Neovim (tar.gz - works on both x86_64 and arm64)
ARG NVIM_VERSION=v0.11.6
RUN ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "amd64" ]; then NVIM_ARCH="x86_64"; else NVIM_ARCH="arm64"; fi && \
    wget -q "https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/nvim-linux-${NVIM_ARCH}.tar.gz" && \
    tar xzf "nvim-linux-${NVIM_ARCH}.tar.gz" && \
    mv "nvim-linux-${NVIM_ARCH}" /opt/nvim && \
    ln -s /opt/nvim/bin/nvim /usr/local/bin/nvim && \
    rm "nvim-linux-${NVIM_ARCH}.tar.gz"

# Eza
ARG EZA_VERSION=0.20.14
RUN ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "amd64" ]; then EZA_ARCH="x86_64"; else EZA_ARCH="aarch64"; fi && \
    wget -q "https://github.com/eza-community/eza/releases/download/v${EZA_VERSION}/eza_${EZA_ARCH}-unknown-linux-gnu.tar.gz" && \
    tar xzf "eza_${EZA_ARCH}-unknown-linux-gnu.tar.gz" -C /usr/local/bin/ && \
    rm "eza_${EZA_ARCH}-unknown-linux-gnu.tar.gz"

# =============================================================================
# Layer 3: NPM/directories/env setup (root)
# =============================================================================
RUN mkdir -p /usr/local/share/npm-global && \
    chown -R node:node /usr/local/share/npm-global

ARG USERNAME=node

# Persist bash history
RUN SNIPPET="export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" && \
    mkdir /commandhistory && \
    touch /commandhistory/.bash_history && \
    chown -R $USERNAME /commandhistory

# Create workspace and config directories
RUN mkdir -p /workspace /home/node/.claude && \
    chown -R node:node /workspace /home/node/.claude

ENV DEVCONTAINER=true
ENV SHELL=/bin/zsh
ENV TERM=xterm-256color

WORKDIR /workspace

# =============================================================================
# Layer 4: User-level tools (as node)
# =============================================================================
USER node

ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin

# zsh-in-docker (Powerlevel10k + plugins)
ARG ZSH_IN_DOCKER_VERSION=1.2.0
RUN sh -c "$(wget -O- https://github.com/deluan/zsh-in-docker/releases/download/v${ZSH_IN_DOCKER_VERSION}/zsh-in-docker.sh)" -- \
    -p git \
    -p fzf \
    -a "source /usr/share/doc/fzf/examples/key-bindings.zsh" \
    -a "source /usr/share/doc/fzf/examples/completion.zsh" \
    -a "export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
    -x

# Claude Code
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Rust + Cargo
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

# Starship prompt
RUN mkdir -p /home/node/.local/bin && \
    curl -sS https://starship.rs/install.sh | sh -s -- --yes --bin-dir /home/node/.local/bin

# Atuin shell history
RUN curl --proto '=https' --tlsv1.2 -LsSf https://setup.atuin.sh | sh

# UV Python package manager
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# Chezmoi
RUN sh -c "$(curl -fsLS get.chezmoi.io)" -- -b /home/node/.local/bin

# fzf-tab plugin
RUN git clone --depth 1 https://github.com/Aloxaf/fzf-tab /home/node/.oh-my-zsh/custom/plugins/fzf-tab

# zsh-z plugin
RUN git clone --depth 1 https://github.com/agkozak/zsh-z /home/node/.oh-my-zsh/custom/plugins/zsh-z

# LazyVim
RUN git clone --depth 1 https://github.com/LazyVim/starter /home/node/.config/nvim && \
    rm -rf /home/node/.config/nvim/.git

# Custom nvim config (baked into image)
COPY --chown=node:node config/nvim/lua/config/options.lua /home/node/.config/nvim/lua/config/options.lua

# Python LSP
RUN /home/node/.local/bin/uv tool install python-lsp-server \
    --with python-lsp-black \
    --with python-lsp-isort \
    --with pylsp-mypy

# =============================================================================
# Layer 5: Firewall + scripts (root)
# =============================================================================
USER root

COPY init-firewall.sh /usr/local/bin/
COPY extra-domains.conf /usr/local/etc/devbox-extra-domains.conf
COPY scripts/setup-chezmoi.sh /usr/local/bin/

RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/setup-chezmoi.sh && \
    echo "node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/node-firewall && \
    chmod 0440 /etc/sudoers.d/node-firewall

# =============================================================================
# Layer 6: Final ENV
# =============================================================================
USER node

ENV PATH="/home/node/.local/bin:/home/node/.cargo/bin:/home/node/.atuin/bin:$PATH"
ENV EDITOR=nvim
ENV VISUAL=nvim
