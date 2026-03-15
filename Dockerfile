FROM node:22

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
    ncdu mc nala libfuse2 xauth xclip ripgrep fd-find \
    build-essential libclang-dev \
    grc curl wget ca-certificates shellcheck \
    && echo "deb http://deb.debian.org/debian bookworm-backports main" > /etc/apt/sources.list.d/backports.list \
    && apt-get update && apt-get install -y --no-install-recommends -t bookworm-backports tmux \
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


# Create workspace and config directories
RUN mkdir -p /workspace /home/node/.claude \
    /home/node/.cursor-server /home/node/.vscode-server && \
    chown -R node:node /workspace /home/node/.claude \
    /home/node/.cursor-server /home/node/.vscode-server

# Pre-populate GitHub SSH host keys (so git works without host known_hosts)
RUN mkdir -p /home/node/.ssh && chmod 700 /home/node/.ssh && \
    ssh-keyscan -t ed25519,rsa github.com >> /home/node/.ssh/known_hosts 2>/dev/null && \
    chmod 600 /home/node/.ssh/known_hosts && \
    chown -R node:node /home/node/.ssh

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
RUN curl --proto '=https' --tlsv1.2 -LsSf https://setup.atuin.sh | sh && \
    mkdir -p /home/node/.local/share/atuin

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
COPY --chown=node:node config/nvim/lua/plugins/markdown-preview.lua /home/node/.config/nvim/lua/plugins/markdown-preview.lua
COPY --chown=node:node config/nvim/lua/plugins/markdown-lint.lua /home/node/.config/nvim/lua/plugins/markdown-lint.lua
COPY --chown=node:node config/nvim/.markdownlint-cli2.yaml /home/node/.config/nvim/.markdownlint-cli2.yaml

# Set PATH early so tree-sitter-cli + claude are available for headless steps
ENV PATH="/home/node/.claude/local/bin:/home/node/.local/bin:/home/node/.cargo/bin:/home/node/.atuin/bin:$PATH"

# Pre-install LazyVim plugins (headless, with retry)
RUN for i in 1 2 3; do \
      nvim --headless "+Lazy! sync" +qa 2>/dev/null && break || sleep 2; \
    done

# Pre-install Mason LSP servers + tools with filesystem-based polling
# Mason API is_installed() has stale-cache issues, so check package dirs on disk instead
RUN nvim --headless \
    -c 'lua (function() \
      local pkgs = {"lua-language-server","bash-language-server","pyright","marksman","dockerfile-language-server","docker-compose-language-service","stylua","shfmt","shellcheck"} \
      local mason_dir = vim.fn.stdpath("data") .. "/mason/packages/" \
      local function is_pkg_installed(name) return vim.fn.isdirectory(mason_dir .. name) == 1 end \
      local max_passes = 3 \
      local pass = 0 \
      local function run_pass() \
        pass = pass + 1 \
        local missing = {} \
        for _, name in ipairs(pkgs) do \
          if not is_pkg_installed(name) then missing[#missing+1] = name end \
        end \
        if #missing == 0 then \
          print("All " .. #pkgs .. " Mason packages installed") \
          vim.cmd("qall"); return \
        end \
        if pass > max_passes then \
          print("Max passes reached, " .. #missing .. " still missing: " .. table.concat(missing, ", ")) \
          vim.cmd("qall"); return \
        end \
        print("Pass " .. pass .. ": installing " .. #missing .. " packages: " .. table.concat(missing, ", ")) \
        vim.cmd("MasonInstall " .. table.concat(missing, " ")) \
        local timer = vim.uv.new_timer() \
        local elapsed = 0 \
        timer:start(15000, 5000, vim.schedule_wrap(function() \
          elapsed = elapsed + 5000 \
          local all_done = true \
          for _, name in ipairs(missing) do \
            if not is_pkg_installed(name) then all_done = false; break end \
          end \
          if all_done or elapsed >= 90000 then \
            timer:stop(); timer:close() \
            if not all_done then print("Pass " .. pass .. " timed out, retrying remaining...") end \
            run_pass() \
          end \
        end)) \
      end \
      vim.defer_fn(function() \
        require("lazy").load({plugins={"mason.nvim","mason-lspconfig.nvim"}}) \
        vim.schedule(run_pass) \
      end, 5000) \
    end)()' \
    2>&1

# Pre-compile Treesitter parsers
# TSInstall completes quickly (~15s), use a simple defer to quit after it finishes
RUN nvim --headless \
    -c 'lua vim.defer_fn(function() \
      require("lazy").load({plugins={"nvim-treesitter"}}) \
      vim.schedule(function() \
        local langs = {"bash","python","lua","dockerfile","markdown","markdown_inline","json","yaml","toml","vim","vimdoc","regex","query"} \
        vim.cmd("TSInstall " .. table.concat(langs, " ")) \
        local timer = vim.uv.new_timer() \
        timer:start(15000, 5000, vim.schedule_wrap(function() \
          local all_done = true \
          for _, lang in ipairs(langs) do \
            local ok = pcall(vim.treesitter.language.inspect, lang) \
            if not ok then all_done = false; break end \
          end \
          if all_done then \
            timer:stop(); timer:close() \
            print("All treesitter parsers installed") \
            vim.cmd("qall") \
          end \
        end)) \
        vim.defer_fn(function() \
          timer:stop(); timer:close() \
          print("TSInstall safety timeout reached") \
          vim.cmd("qall") \
        end, 120000) \
      end) \
    end, 3000)' \
    2>&1

# Tmux Plugin Manager + config
RUN git clone --depth 1 https://github.com/tmux-plugins/tpm /home/node/.config/tmux/plugins/tpm
COPY --chown=node:node config/tmux/tmux.conf /home/node/.config/tmux/tmux.conf
RUN TMUX_PLUGIN_MANAGER_PATH="/home/node/.config/tmux/plugins" \
    /home/node/.config/tmux/plugins/tpm/bin/install_plugins

# Symlink for chezmoi dotfiles compatibility (tmux.conf references ~/.tmux/plugins/tpm/tpm)
RUN mkdir -p /home/node/.tmux && \
    ln -s /home/node/.config/tmux/plugins /home/node/.tmux/plugins

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

# Build stamp for volume freshness detection (must be after all nvim build steps)
# Written to both /opt/ (survives volume mount) and nvim data dir (Docker copies to fresh volumes)
RUN STAMP=$(date +%s) && \
    echo "$STAMP" > /opt/nvim-build-stamp && \
    echo "$STAMP" > /home/node/.local/share/nvim/.nvim-build-stamp && \
    chown node:node /home/node/.local/share/nvim/.nvim-build-stamp

# Ensure npm-global bin is in PATH for all zsh sessions (survives chezmoi dotfiles)
RUN echo 'export PATH="$PATH:/usr/local/share/npm-global/bin"' >> /etc/zsh/zshenv

# Shared firewall allowlist mount point (bind-mounted :ro from host)
RUN mkdir -p /etc/devbox-shared

COPY init-firewall.sh /usr/local/bin/
COPY extra-domains.conf /usr/local/etc/devbox-extra-domains.conf
COPY scripts/setup-chezmoi.sh /usr/local/bin/
COPY scripts/n scripts/nx /usr/local/bin/
COPY scripts/start-rootless-docker.sh /usr/local/bin/
COPY scripts/devbox-entrypoint.sh /usr/local/bin/
COPY scripts/setup-claude.sh /usr/local/bin/
COPY scripts/setup-nvim-data.sh /usr/local/bin/

RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/setup-chezmoi.sh \
    /usr/local/bin/n /usr/local/bin/nx /usr/local/bin/start-rootless-docker.sh \
    /usr/local/bin/devbox-entrypoint.sh \
    /usr/local/bin/setup-claude.sh /usr/local/bin/setup-nvim-data.sh

# Sudo with password — prevents AI agents from modifying firewall rules
# Password is injected via --mount=type=secret (never stored in image layers/metadata)
# Build with: docker build --secret id=sudo_password,src=<file> ...
# Falls back to "devbox" if no secret is provided
# NOTE: SUDO_CACHE_BUST forces cache invalidation — secret content alone doesn't bust cache
ARG SUDO_CACHE_BUST
RUN --mount=type=secret,id=sudo_password \
    PASS=$(cat /run/secrets/sudo_password 2>/dev/null || echo "devbox") && \
    echo "node:${PASS}" | chpasswd && \
    usermod -aG sudo node

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
