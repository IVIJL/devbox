# Devbox - Personal Dev Container

Portable development environment built on Claude Code devcontainer (node:20/Debian) with a default-deny firewall. Claude Code can run with `--dangerously-skip-permissions` without risk to the host system.

## Quick Start

### 1. Build the image

```bash
docker build -t vlcak/devbox:latest .
```

### 2. Run standalone (terminal)

```bash
# Standalone with persistent workspace volume
./docker-run.sh

# Mount a project directory
./docker-run.sh /path/to/project
```

Set `ANTHROPIC_API_KEY` before running:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
./docker-run.sh
```

### 3. Use with Cursor / VS Code

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
  "runArgs": ["--privileged"],
  "features": {
    "ghcr.io/devcontainers/features/docker-in-docker:2": {}
  },
  "remoteUser": "node",
  "mounts": [
    "source=${localEnv:HOME}/.ssh/config,target=/home/node/.ssh/config,type=bind,readonly",
    "source=${localEnv:HOME}/.ssh/known_hosts,target=/home/node/.ssh/known_hosts,type=bind,readonly",
    "source=devbox-bashhistory-${devcontainerId},target=/commandhistory,type=volume",
    "source=devbox-claude-config-${devcontainerId},target=/home/node/.claude,type=volume"
  ],
  "containerEnv": {
    "NODE_OPTIONS": "--max-old-space-size=4096",
    "CLAUDE_CONFIG_DIR": "/home/node/.claude",
    "TZ": "${localEnv:TZ:Europe/Prague}"
  },
  "workspaceMount": "source=${localWorkspaceFolder},target=/workspace,type=bind,consistency=delegated",
  "workspaceFolder": "/workspace",
  "postStartCommand": "sudo /usr/local/bin/init-firewall.sh && /usr/local/bin/setup-chezmoi.sh",
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
| `docker` | Docker-in-Docker (containers inside devbox) |
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
| `mc`, `ncdu`, `jq`, `grc` | Utilities |

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

## Docker-in-Docker

Devbox includes Docker CE inside the container, so you can run containers within your dev environment. This is useful for running dev services (databases, web servers) in isolation while keeping them accessible from your host browser.

### How it works

- **Cursor/VS Code**: The devcontainer feature `docker-in-docker:2` handles starting dockerd automatically. Just use `docker` commands normally.
- **docker-run.sh**: dockerd is started in the background on container launch. Docker data is persisted in the `devbox-docker` volume.

### Port forwarding

- **Cursor/VS Code**: Ports are forwarded automatically. VS Code detects listening ports and tunnels them to `localhost` on the host.
- **docker-run.sh**: Add `-p` flags before the image name for port forwarding:
  ```bash
  # Edit docker-run.sh DOCKER_ARGS or pass ports manually:
  docker run -p 3000:3000 -p 5432:5432 ...
  ```

### Example usage

```bash
# Inside devbox:
docker run hello-world                          # verify DinD works
docker run -d -p 5432:5432 postgres:16          # start a dev database
docker compose up -d                            # start a full dev stack
```

### Security note

DinD requires `--privileged` mode, which is a significant escalation from the previous `NET_ADMIN + NET_RAW` capabilities. This is acceptable because:
- This is a local dev environment on WSL2
- WSL2 itself provides a hypervisor boundary
- The firewall script still works (privileged includes all capabilities)

## Dotfiles

Chezmoi initializes from `github.com/IVIJL/vlci-dotfiles` on every container start (postStart). Dotfiles are applied with `--force`, overriding the default zsh-in-docker config. This is intentional.

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
    └── setup-chezmoi.sh            # postStart: chezmoi init + apply
```
