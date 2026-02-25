# Devbox - Personal Dev Container

Portable development environment built on Claude Code devcontainer (node:22/Debian) with a default-deny firewall. Claude Code can run with `--dangerously-skip-permissions` without risk to the host system.

## Quick Start

### Automated Install

```bash
# Download and review first (recommended):
curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/IVIJL/devbox/main/install.sh -o install.sh
less install.sh
bash install.sh

# Or one-liner:
curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/IVIJL/devbox/main/install.sh | bash -s -- --yes
```

This installs git, Docker, and keychain, configures SSH agent, clones the repo, builds the image, and installs the `devbox` command. Run `install.sh --help` for details.

### Manual Install

#### 1. Build the image

```bash
./build.sh
```

#### 2. Install the `devbox` command

```bash
sudo ln -s $(realpath docker-run.sh) /usr/local/bin/devbox
```

Set `ANTHROPIC_API_KEY` before running:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
devbox
```

#### 3. Use with Cursor / VS Code

##### A) This repository (devbox itself)

Open this folder in Cursor/VS Code, then **Dev Containers: Reopen in Container**. It uses `.devcontainer/devcontainer.json` automatically.

##### B) Any other project

Copy a minimal devcontainer config into your project:

```bash
mkdir -p /path/to/project/.devcontainer
cat > /path/to/project/.devcontainer/devcontainer.json << 'EOF'
{
  "name": "Devbox",
  "image": "vlcak/devbox:latest",
  "runArgs": [
    "--security-opt", "seccomp=unconfined",
    "--security-opt", "apparmor=unconfined",
    "--security-opt", "systempaths=unconfined",
    "--cap-add=SYS_ADMIN",
    "--cap-add=NET_ADMIN",
    "--cap-add=NET_RAW",
    "--device=/dev/net/tun",
    "--device=/dev/fuse"
  ],
  "remoteUser": "node",
  "mounts": [
    "source=${localEnv:HOME}/.gitconfig,target=/home/node/.gitconfig-host,type=bind,readonly",
    "source=devbox-claude-config-${devcontainerId},target=/home/node/.claude,type=volume",
    "source=devbox-docker-${devcontainerId},target=/home/node/.local/share/docker,type=volume",
    "source=devbox-cursor-server-${devcontainerId},target=/home/node/.cursor-server,type=volume",
    "source=devbox-vscode-server-${devcontainerId},target=/home/node/.vscode-server,type=volume"
  ],
  "containerEnv": {
    "NODE_OPTIONS": "--max-old-space-size=4096",
    "CLAUDE_CONFIG_DIR": "/home/node/.claude",
    "TZ": "${localEnv:TZ:Europe/Prague}"
  },
  "workspaceMount": "source=${localWorkspaceFolder},target=/workspace,type=bind,consistency=delegated",
  "workspaceFolder": "/workspace",
  "postStartCommand": "sudo cp /home/node/.gitconfig-host /etc/gitconfig 2>/dev/null || true; sudo /usr/local/bin/init-firewall.sh && /usr/local/bin/start-rootless-docker.sh && /usr/local/bin/setup-chezmoi.sh",
  "waitFor": "postStartCommand"
}
EOF
```

Then open the project in Cursor/VS Code and **Dev Containers: Reopen in Container**.

## CLI Reference

Run `devbox --help` for the full list. Summary:

| Command | Description |
|---|---|
| `devbox [--ssh-config] [path]` | Start/attach container for project (default: CWD) |
| `devbox <name>` | Attach to running `devbox-<name>` container |
| `devbox ls` | List running and exited containers |
| `devbox stop [name] [--clean]` | Stop container; `--clean` removes Docker/history volumes |
| `devbox remove [name]` | Remove project data (volumes) interactively |
| `devbox port <port>` | Expose port via Traefik for all running containers |
| `devbox ports` | List active port routes |
| `devbox allow [domain]` | List allowed domains, or add one |
| `devbox deny [domain]` | Remove allowed domain (interactive if no arg) |
| `devbox blocked` | Show blocked DNS queries, allow interactively via fzf |
| `devbox cursor [name]` | Open Cursor attached to running devbox |
| `devbox code [name]` | Open VS Code attached to running devbox |
| `devbox clip` | Grab clipboard image for container use |
| `devbox ssh-config [add\|edit]` | Manage devbox-specific SSH config |

## Build

```bash
./build.sh                       # Build image (uses cache)
./build.sh --no-cache            # Full rebuild without cache
./build.sh --progress=plain      # Show full build log
./build.sh --clean               # Full reset + rebuild
./build.sh --uninstall           # Full reset without rebuild
```

All other flags pass through to `docker build`. Set `DEVBOX_SUDO_PASSWORD` env var for non-interactive builds. Run `./build.sh --help` for details.

## Firewall

The container starts with a default-deny firewall (iptables + ipset + dnsmasq). Only domains listed in `~/.config/devbox/allowed-domains.conf` can be reached. GitHub is allowed by IP range.

Default allowed domains include Anthropic API, npm, PyPI, crates.io, VS Code marketplace, Cursor, and Docker Hub. The file is seeded on first run and can be edited manually or via CLI commands.

### Managing domains

```bash
devbox allow                     # List all allowed domains
devbox allow pypi.org            # Add domain to allowlist
devbox deny                      # Interactive removal (fzf)
devbox deny example.com          # Remove specific domain
devbox blocked                   # Show blocked DNS queries, allow interactively
```

Changes take effect immediately across all running containers — dnsmasq is reloaded and ipset rules are updated without restart.

## Port Routing

Devbox uses a shared Traefik reverse proxy to route HTTP traffic to containers by hostname.

```bash
devbox port 3000                 # Expose port 3000 on all containers
devbox ports                     # List active routes
```

URL format: `http://<port>.<project>.127.0.0.1.traefik.me`

For example, running `devbox port 3000` in a project called `my-app` creates:
`http://3000.my-app.127.0.0.1.traefik.me` → `devbox-my-app:3000`

Default ports (3000, 5173, 8080, etc.) are applied automatically on container start. The list is stored in `~/.config/devbox/default-ports.conf` and can be edited.

## Multi-session

Multiple devbox containers can run simultaneously for different projects. Each gets its own:

- Container (`devbox-<project>`)
- Docker volume (`devbox-<project>-docker`)
- Shell history volume (`devbox-<project>-history`)
- Traefik port routes (namespaced by project name)

Shared across all containers:
- Claude config volume (`devbox-claude-config`)
- Neovim data volume (`devbox-nvim-data`)
- Cursor server volume (`devbox-cursor-server`)
- VS Code server volume (`devbox-vscode-server`)
- Firewall allowlist (`~/.config/devbox/allowed-domains.conf`)
- Host `~/.claude/` directory (read-only, for user-level `CLAUDE.md`)
- Host `~/.config/git/ignore` (global gitignore)
- Traefik proxy (`devbox-traefik`)

```bash
devbox ~/projects/app-a          # Start first project
devbox ~/projects/app-b          # Start second project (new terminal)
devbox ls                        # List all running containers
```

## Environment Variables

| Variable | Description |
|---|---|
| `ANTHROPIC_API_KEY` | API key for Claude Code |
| `DEVBOX_SUDO_PASSWORD` | Sudo password for non-interactive builds (default: `devbox`) |
| `CHEZMOI_REPO` | Chezmoi dotfiles repo (default in docker-run.sh: `github.com/IVIJL/vlci-dotfiles`; empty = skip) |
| `NTFY_TOKEN` | ntfy.sh notification token (auto-detected from Claude hooks) |
| `TZ` | Timezone (default: `Europe/Prague`) |

## Docker-in-Docker (Rootless)

The container includes a full rootless Docker daemon. It starts automatically on container launch and supports `docker build`, `docker run`, and `docker compose`.

```bash
# Inside devbox:
docker run hello-world
docker compose up -d
docker build -t myapp .
```

### How it works

Docker runs as the `node` user via `dockerd-rootless.sh` — no `--privileged` flag, no host socket mounting. The daemon uses `fuse-overlayfs` as the storage driver and `slirp4netns` for networking.

**Security:** The container runs with `seccomp=unconfined`, `apparmor=unconfined`, `systempaths=unconfined`, and `CAP_SYS_ADMIN` (all required by rootless Docker for user namespaces and sysctl access). Devices `/dev/net/tun` and `/dev/fuse` are exposed for networking and storage. The container is **not** privileged. An escape would require a kernel exploit.

### Docker data persistence

Docker images and containers are stored in a per-project named volume (`devbox-<project>-docker`), so they survive container restarts without re-pulling images. Volumes persist across `devbox stop` but can be cleaned with `devbox stop --clean` or `devbox remove`.

### Graceful shutdown

The container uses `devbox-entrypoint.sh` as PID 1, which traps SIGTERM and gracefully stops all inner DinD containers before exiting. This prevents database corruption on `devbox stop` or host reboot.

The shutdown chain: host Docker → SIGTERM → entrypoint trap → `docker stop` inner containers → inner processes flush/shutdown → entrypoint exits. Additionally, `devbox stop` runs a pre-stop hook that explicitly stops inner containers before sending SIGTERM to the entrypoint (belt-and-suspenders).

The container uses `--stop-timeout 45` to allow sufficient time for inner containers with databases to shut down cleanly.

## Included Tools

| Tool | Description |
|---|---|
| `claude` | Claude Code CLI |
| `nvim` | Neovim with LazyVim |
| `git` + `delta` | Git with delta diff viewer |
| `eza` | Modern `ls` replacement |
| `rg` | ripgrep |
| `fd` | Fast file finder |
| `fzf` | Fuzzy finder |
| `starship` | Cross-shell prompt |
| `atuin` | Shell history search |
| `uv` | Python package manager |
| `rustc` / `cargo` | Rust toolchain |
| `chezmoi` | Dotfile manager |
| `docker` | Docker CE (rootless DinD) with compose and buildx |
| `mc`, `ncdu`, `jq`, `grc` | Utilities |

## SSH (Agent Forwarding)

Private SSH keys are **never** mounted into the container. Instead, the container uses SSH agent forwarding - only the agent socket is shared, so the container can request signatures but never access the key material.

Inside the container, verify with `ssh-add -l` (should list your keys).

Host `~/.ssh/config` and `~/.ssh/known_hosts` are **not mounted by default** to prevent leaking server addresses and usernames. GitHub SSH host keys are pre-populated in the image, so `git push/pull` works out of the box.

### Devbox SSH config

To configure SSH hosts for use inside devbox without exposing your full host config:

```bash
devbox ssh-config                # Show current config
devbox ssh-config add            # Add host interactively
devbox ssh-config edit           # Open in $EDITOR
```

The config is stored in `~/.config/devbox/ssh_config` and automatically mounted into every container. Remember to also allow the domain in the firewall (`devbox allow example.com`).

### Full host SSH config

To temporarily mount your full host `~/.ssh/config` and `~/.ssh/known_hosts`:

```bash
devbox --ssh-config              # Mount with host SSH config
devbox --ssh-config ~/project    # Specific project with host SSH config
```

This flag only takes effect on container creation. For a running container: `devbox stop && devbox --ssh-config`.

**Cursor/VS Code** handles SSH agent forwarding automatically via the devcontainers extension.

### Persistent SSH Agent on WSL2 (Host Setup)

By default, `ssh-agent` dies when you close your terminal. To keep it running across all terminals, install `keychain` on the **host** (not inside devbox):

```bash
sudo apt install keychain
```

Add to your host `~/.zshrc` (or `~/.bashrc`):

```zsh
eval $(keychain --eval --quiet --agents ssh)
```

Add to `~/.ssh/config` (private file, not in any public repo):

```
Host *
    AddKeysToAgent yes
```

This starts one `ssh-agent` per boot, shared across all terminals. Keys are added automatically on first SSH use (passphrase prompted once per boot). No key names are exposed in your shell config.

<details>
<summary>Alternative approaches</summary>

| Method | Needs systemd? | Extra install? | Complexity |
|---|---|---|---|
| `keychain` (recommended) | No | `keychain` pkg | Low |
| systemd user service | Yes (`systemd=true` in wsl.conf) | None | Low |
| Fixed socket path in `.zshrc` | No | None | Low |
| npiperelay (Windows agent bridge) | No | `socat` + `npiperelay.exe` | Medium |

</details>

## Clipboard Image Paste

Paste images from your host clipboard into Claude Code conversations inside the container. The `devbox clip` command grabs the current clipboard image, saves it to `~/.clipboard-images/`, and prints the path. Claude Code can then read the image from that path.

Works on WSL2 (PowerShell clipboard), Linux X11 (`xclip`), and Linux Wayland (`wl-paste`).

```bash
devbox clip                      # Grab clipboard image, print path
```

### WezTerm keybinding

Add a keybinding to your `~/.wezterm.lua` so `Ctrl+Shift+S` grabs the clipboard image and pastes its path into the terminal. This snippet auto-detects WSL vs native Linux:

```lua
{
  key = "s",
  mods = "CTRL|SHIFT",
  action = wezterm.action_callback(function(window, pane)
    local cmd
    local handle = io.popen("command -v wsl.exe 2>/dev/null")
    local has_wsl = handle and handle:read("*a"):gsub("%s+$", "") ~= ""
    if handle then handle:close() end
    if has_wsl then
      -- WSL: use default distro, bash -lc expands $HOME automatically
      cmd = { "wsl.exe", "--", "bash", "-lc",
              "$HOME/.local/share/devbox/scripts/clip-image.sh" }
    else
      -- Native Linux: call script directly
      cmd = { os.getenv("HOME") .. "/.local/share/devbox/scripts/clip-image.sh" }
    end
    local success, stdout, _ = wezterm.run_child_process(cmd)
    if success then
      pane:send_text(stdout:gsub("%s+$", ""))
    else
      window:toast_notification("devbox clip", "No image in clipboard", nil, 3000)
    end
  end),
},
```

Images older than 24 hours are cleaned up automatically on each invocation.

## Dotfiles

Chezmoi dotfiles are configured via the `CHEZMOI_REPO` environment variable. In `docker-run.sh` it defaults to `github.com/IVIJL/vlci-dotfiles`. Set your own repo or leave it empty to skip chezmoi initialization.

Chezmoi runs on every container start (postStart). Dotfiles are applied with `--force`, overriding any default config. To update dotfiles without rebuilding: just restart the container.

## File Structure

```
devbox/
├── Dockerfile                      # Main image
├── .devcontainer/
│   ├── devcontainer.json           # For Cursor/VS Code (this repo)
│   └── cursor/
│       └── devcontainer.json       # Cursor-specific config (pre-built image)
├── devcontainer-standalone.json    # For standalone devcontainer CLI usage
├── docker-run.sh                   # CLI entrypoint (devbox command)
├── build.sh                        # Build script with cleanup
├── install.sh                      # Automated installer
├── init-firewall.sh                # Default-deny firewall (iptables/ipset/dnsmasq)
├── extra-domains.conf              # Build-time extra allowed domains
├── config/
│   ├── claude/                     # Claude Code config
│   ├── nvim/                       # Neovim config
│   └── tmux/                       # Tmux config
└── scripts/
    ├── devbox-entrypoint.sh        # Container PID 1 with graceful shutdown
    ├── clip-image.sh               # Clipboard image grab (WSL/X11/Wayland)
    ├── setup-chezmoi.sh            # postStart: chezmoi init + apply
    ├── setup-claude.sh             # postStart: Claude Code setup
    ├── setup-nvim-data.sh          # Neovim data initialization
    └── start-rootless-docker.sh    # postStart: rootless Docker daemon
```

### Host-side files

```
~/.config/devbox/
├── allowed-domains.conf            # Firewall allowlist (shared to all containers)
├── default-ports.conf              # Default ports for Traefik routing
├── ssh_config                      # Devbox-specific SSH config (mounted as ~/.ssh/config)
└── traefik/
    └── dynamic/                    # Traefik route configs (auto-generated)

~/.config/git/
└── ignore                          # Global gitignore (mounted live into containers)

~/.claude/
└── CLAUDE.md                       # User-level Claude instructions (mounted live into containers)

~/.clipboard-images/                # Shared clipboard images (host ↔ container)
```
