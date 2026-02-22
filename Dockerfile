FROM node:20

ARG TZ=Europe/Prague
ENV TZ="$TZ"

# =============================================================================
# Layer 1: APT packages (Claude Code base + user tools)
# =============================================================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Claude Code packages
    less git procps sudo zsh man-db unzip gnupg2 gh \
    iptables ipset iproute2 dnsutils aggregate jq nano vim dnsmasq iputils-ping \
    # Rootless Docker prerequisites
    uidmap fuse-overlayfs slirp4netns \
    # User packages
    ncdu mc nala libfuse2 xauth xclip ripgrep fd-find tmux \
    build-essential libclang-dev \
    grc curl wget ca-certificates \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && ln -s "$(which fdfind)" /usr/local/bin/fd

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
# Layer 3: Docker CE (rootless)
# =============================================================================
RUN install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list && \
    apt-get update && apt-get install -y --no-install-recommends \
    docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin \
    docker-ce-rootless-extras && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Rootless Docker: subordinate UID/GID mapping
RUN echo "node:100000:65536" >> /etc/subuid && \
    echo "node:100000:65536" >> /etc/subgid

# Rootless Docker: runtime directories and config
RUN mkdir -p /run/user/1000 && chown node:node /run/user/1000 && \
    mkdir -p /home/node/.local/share/docker && chown -R node:node /home/node/.local && \
    mkdir -p /home/node/.config/docker && \
    echo '{"storage-driver": "fuse-overlayfs"}' > /home/node/.config/docker/daemon.json && \
    chown -R node:node /home/node/.config

# =============================================================================
# Layer 4: NPM/directories/env setup (root)
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

# Claude Code config defaults (template — seeded into volume at startup)
COPY --chown=node:node config/claude/ /etc/claude-defaults/
RUN chmod +x /etc/claude-defaults/hooks/*.sh /etc/claude-defaults/statusline-info.sh

ENV DEVCONTAINER=true
ENV SHELL=/bin/zsh
ENV TERM=xterm-256color
ENV LANG=C.UTF-8

WORKDIR /workspace

# ZSH plugins (installed to /usr/share/ for chezmoi .zshrc sourcing)
RUN git clone --depth 1 https://github.com/zsh-users/zsh-autosuggestions /usr/share/zsh-autosuggestions && \
    git clone --depth 1 https://github.com/agkozak/zsh-z.git /usr/share/zsh-z && \
    git clone --depth 1 https://github.com/zsh-users/zsh-syntax-highlighting.git /usr/share/zsh-syntax-highlighting && \
    git clone --depth 1 https://github.com/Aloxaf/fzf-tab /usr/share/fzf-tab

# =============================================================================
# Layer 5: User-level tools (as node)
# =============================================================================
USER node

ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin

# fzf keybindings + completion (CTRL-R, CTRL-T, **(TAB))
RUN git clone --depth 1 https://github.com/junegunn/fzf.git /home/node/.fzf && \
    /home/node/.fzf/install --all

# Claude Code (native binary installer)
RUN curl -fsSL https://claude.ai/install.sh | bash

# Rust + Cargo
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

# tree-sitter-cli from source (pre-built binary AND Mason's binary both need GLIBC 2.39, Bookworm has 2.36)
# Clean cargo build cache afterwards to reduce image size
RUN . "$HOME/.cargo/env" && cargo install tree-sitter-cli && \
    rm -rf "$HOME/.cargo/registry" "$HOME/.cargo/git"

# Starship prompt
RUN mkdir -p /home/node/.local/bin && \
    curl -sS https://starship.rs/install.sh | sh -s -- --yes --bin-dir /home/node/.local/bin

# Atuin shell history
RUN curl --proto '=https' --tlsv1.2 -LsSf https://setup.atuin.sh | sh

# UV Python package manager
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# Chezmoi
RUN sh -c "$(curl -fsLS get.chezmoi.io)" -- -b /home/node/.local/bin

# LazyVim starter + cleanup
RUN git clone --depth 1 https://github.com/LazyVim/starter /home/node/.config/nvim && \
    rm -rf /home/node/.config/nvim/.git && \
    rm -f /home/node/.config/nvim/lua/plugins/example.lua

# Custom nvim configs (baked into image)
COPY --chown=node:node config/nvim/lua/config/options.lua /home/node/.config/nvim/lua/config/options.lua
COPY --chown=node:node config/nvim/lua/config/lazy.lua /home/node/.config/nvim/lua/config/lazy.lua
COPY --chown=node:node config/nvim/lua/plugins/pylsp.lua /home/node/.config/nvim/lua/plugins/pylsp.lua
COPY --chown=node:node config/nvim/lua/plugins/treesitter-parsers.lua /home/node/.config/nvim/lua/plugins/treesitter-parsers.lua
COPY --chown=node:node config/nvim/lua/plugins/ruff.lua /home/node/.config/nvim/lua/plugins/ruff.lua

# Set PATH early so tree-sitter-cli + claude are available for headless steps
ENV PATH="/home/node/.claude/local/bin:/home/node/.local/bin:/home/node/.cargo/bin:/home/node/.atuin/bin:$PATH"

# Pre-install LazyVim plugins (headless, with retry)
RUN for i in 1 2 3; do \
      nvim --headless "+Lazy! sync" +qa 2>/dev/null && break || sleep 2; \
    done

# Pre-install Mason LSP servers + tools, then trigger blink.cmp + treesitter parsers
# (auto-install needs FileType events that don't fire in headless mode)
# Mason is lazy-loaded, so defer the command to let plugins finish loading first
RUN nvim --headless \
    -c 'lua vim.defer_fn(function() require("lazy").load({plugins={"mason.nvim","mason-lspconfig.nvim"}}) vim.schedule(function() local ok, err = pcall(vim.cmd, "MasonInstall lua-language-server bash-language-server pyright marksman dockerfile-language-server docker-compose-language-service stylua shfmt shellcheck") if not ok then vim.notify("MasonInstall: " .. err, vim.log.levels.WARN) end end) end, 5000)' \
    -c 'lua vim.defer_fn(function() vim.cmd("qall") end, 120000)' \
    2>&1 && \
    nvim --headless \
    -c 'lua vim.defer_fn(function() vim.cmd("qall") end, 90000)' \
    2>&1

# Tmux Plugin Manager + config
RUN git clone --depth 1 https://github.com/tmux-plugins/tpm /home/node/.tmux/plugins/tpm
COPY --chown=node:node config/tmux/tmux.conf /home/node/.config/tmux/tmux.conf
RUN TMUX_PLUGIN_MANAGER_PATH="/home/node/.tmux/plugins" \
    /home/node/.tmux/plugins/tpm/bin/install_plugins

# Python LSP
RUN /home/node/.local/bin/uv tool install python-lsp-server \
    --with python-lsp-black \
    --with python-lsp-isort \
    --with pylsp-mypy

# Ruff linter/formatter
RUN /home/node/.local/bin/uv tool install ruff

# =============================================================================
# Layer 6: Firewall + scripts (root)
# =============================================================================
USER root

COPY init-firewall.sh /usr/local/bin/
COPY extra-domains.conf /usr/local/etc/devbox-extra-domains.conf
COPY scripts/setup-chezmoi.sh /usr/local/bin/
COPY scripts/n scripts/nx /usr/local/bin/
COPY scripts/start-rootless-docker.sh /usr/local/bin/
COPY scripts/setup-claude.sh /usr/local/bin/

RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/setup-chezmoi.sh \
    /usr/local/bin/n /usr/local/bin/nx /usr/local/bin/start-rootless-docker.sh \
    /usr/local/bin/setup-claude.sh

RUN printf '%s\n' 'node ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/node-nopasswd && \
    chmod 0440 /etc/sudoers.d/node-nopasswd

# X11 forwarding support
RUN printf '%s\n' 'Defaults env_keep += "DISPLAY XAUTHORITY"' > /etc/sudoers.d/x11-forward && \
    chmod 440 /etc/sudoers.d/x11-forward && \
    touch /home/node/.Xauthority && chmod 600 /home/node/.Xauthority && \
    chown node:node /home/node/.Xauthority

# =============================================================================
# Layer 7: Final ENV
# =============================================================================
USER node

ENV EDITOR=nvim
ENV VISUAL=nvim
ENV XDG_RUNTIME_DIR=/run/user/1000
ENV DOCKER_HOST=unix:///run/user/1000/docker.sock
