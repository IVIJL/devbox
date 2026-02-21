# Devbox - Personal Dev Container

Portable development environment built on Claude Code devcontainer (node:20/Debian) with a default-deny firewall. Claude Code can run with `--dangerously-skip-permissions` without risk to the host system.

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
docker build -t vlcak/devbox:latest .
```

#### 2. Run standalone (terminal)

Install the `devbox` command globally:

```bash
sudo ln -s $(realpath docker-run.sh) /usr/local/bin/devbox
```

Then use it from any project directory:

```bash
cd ~/projects/my-app
devbox                          # mounts current directory as /workspace
devbox /path/to/other/project   # mount a specific directory
```

Set `ANTHROPIC_API_KEY` before running:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
devbox
```

#### 3. Use with Cursor / VS Code

#### A) This repository (devbox itself)

Open this folder in Cursor/VS Code, then **Dev Containers: Reopen in Container**. It uses `.devcontainer/devcontainer.json` automatically.

#### B) Any other project

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
    "source=${localEnv:HOME}/.gitconfig,target=/etc/gitconfig,type=bind,readonly",
    "source=${localEnv:HOME}/.ssh/config,target=/home/node/.ssh/config,type=bind,readonly",
    "source=${localEnv:HOME}/.ssh/known_hosts,target=/home/node/.ssh/known_hosts,type=bind,readonly",
    "source=devbox-bashhistory-${devcontainerId},target=/commandhistory,type=volume",
    "source=devbox-claude-config-${devcontainerId},target=/home/node/.claude,type=volume",
    "source=devbox-docker-${devcontainerId},target=/home/node/.local/share/docker,type=volume"
  ],
  "containerEnv": {
    "NODE_OPTIONS": "--max-old-space-size=4096",
    "CLAUDE_CONFIG_DIR": "/home/node/.claude",
    "TZ": "${localEnv:TZ:Europe/Prague}"
  },
  "workspaceMount": "source=${localWorkspaceFolder},target=/workspace,type=bind,consistency=delegated",
  "workspaceFolder": "/workspace",
  "postStartCommand": "sudo /usr/local/bin/init-firewall.sh && /usr/local/bin/start-rootless-docker.sh && /usr/local/bin/setup-chezmoi.sh",
  "waitFor": "postStartCommand"
}
EOF
```

Then open the project in Cursor/VS Code and **Dev Containers: Reopen in Container**.

## Environment Variables

| Variable | Description |
|---|---|
| `ANTHROPIC_API_KEY` | API key for Claude Code |
| `DEVBOX_EXTRA_DOMAINS` | Comma-separated extra domains to allow through the firewall |
| `TZ` | Timezone (default: `Europe/Prague`) |

## Firewall

The container starts with a default-deny firewall. Only these destinations are allowed:

- **GitHub** (IP ranges from API)
- **npm registry** (`registry.npmjs.org`)
- **Anthropic API** (`api.anthropic.com`)
- **Sentry, Statsig** (telemetry)
- **VS Code marketplace** (extensions)
- **rep.gaiagroup.cz**
- Anything in `extra-domains.conf` or `DEVBOX_EXTRA_DOMAINS`

### Adding extra domains

Per-image (persistent): edit `extra-domains.conf` and rebuild.

Per-run (temporary):

```bash
DEVBOX_EXTRA_DOMAINS="pypi.org,files.pythonhosted.org" ./docker-run.sh
```

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

### Port forwarding

Ports exposed by inner containers are available on the devbox's network. In Cursor/VS Code, use the Ports tab to forward them to your host. With `docker-run.sh`, add `-p` flags:

```bash
# Forward port 3000 from inner container to host
docker run -p 3000:3000 ... vlcak/devbox:latest ...
```

### Docker data persistence

Docker images and containers are stored in a named volume (`devbox-docker`), so they survive container restarts without re-pulling images.

## SSH (Agent Forwarding)

Private SSH keys are **never** mounted into the container. Instead, the container uses SSH agent forwarding - only the agent socket is shared, so the container can request signatures but never access the key material.

Inside the container, verify with `ssh-add -l` (should list your keys).

Only `~/.ssh/config` and `~/.ssh/known_hosts` are bind-mounted (read-only) for host/proxy configuration.

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

## Dotfiles

Chezmoi initializes from `github.com/IVIJL/vlci-dotfiles` on every container start (postStart). Dotfiles are applied with `--force`, overriding any default config.

To update dotfiles without rebuilding: just restart the container.

## Rebuilding

```bash
# Full rebuild
docker build -t vlcak/devbox:latest .

# No-cache rebuild (e.g. to get latest Claude Code)
docker build --no-cache -t vlcak/devbox:latest .
```

## File Structure

```
devbox/
├── Dockerfile                      # Main image
├── .devcontainer/
│   └── devcontainer.json           # For Cursor/VS Code (this repo)
├── devcontainer-standalone.json    # For standalone devcontainer CLI usage
├── init-firewall.sh                # Default-deny firewall
├── extra-domains.conf              # Extra allowed domains
├── docker-run.sh                   # Terminal convenience script
└── scripts/
    ├── setup-chezmoi.sh            # postStart: chezmoi init + apply
    └── start-rootless-docker.sh    # postStart: rootless Docker daemon
```
