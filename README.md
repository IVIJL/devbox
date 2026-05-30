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
| `devbox allow-for [N] [name]` | Open an N-minute window that records (not blocks) non-allowlist DNS; `--stop` closes early |
| `devbox agent-browser <start\|stop\|status\|allow-for> [args]` | Drive a hardened host Chrome from inside the container; `allow-for` opens an N-minute proxy harvest window |
| `devbox mcp <import\|list\|render\|doctor\|add\|install\|enable\|disable\|remove> [args]` | Manage Container MCP servers: import host agent config, render devbox-managed entries, diagnose, materialize runtime |
| `devbox cursor [name]` | Open Cursor attached to running devbox |
| `devbox code [name]` | Open VS Code attached to running devbox |
| `devbox clip` | Grab clipboard image for container use |
| `devbox ssh-config [add\|edit]` | Manage devbox-specific SSH config |
| `devbox claude-token` | Generate/regenerate Claude Code OAuth token |
| `devbox update` | Pull latest devbox repo and rebuild image |
| `devbox prune` | Remove Docker build cache and dangling images (reclaim disk space) |
| `devbox uninstall [--purge-ca]` | Remove all containers, volumes, image; `--purge-ca` also strips the mkcert root CA from native + Windows trust stores |

## Build

```bash
devbox build                     # Build image (uses cache)
devbox build --no-cache          # Full rebuild without cache
devbox build --progress=plain    # Show full build log
devbox build --clean             # Full reset (volumes + cache) + rebuild
devbox prune                     # Remove build cache only — no volumes, no rebuild
devbox update                    # Pull latest repo + rebuild image
```

`devbox build --clean` stops all containers, removes all devbox volumes, clears build cache, and rebuilds. Use `devbox prune` to reclaim build cache space (typically 10–20 GB after many builds) without touching volumes or triggering a rebuild.

All other flags pass through to `docker build`. Set `DEVBOX_SUDO_PASSWORD` env var for non-interactive builds. Run `./build.sh --help` for details.

## Zsh Completion

Tab completion is included for all `devbox` commands. It is installed automatically by `install.sh` and updated on `devbox update`.

- `devbox <TAB>` — shows all commands with descriptions
- `devbox stop <TAB>` — shows running container names
- `devbox build <TAB>` — shows `--clean`, `--no-cache`, `--progress=plain`
- `devbox ssh-config <TAB>` — shows `add`, `edit`

**Manual install** (if you skipped `install.sh`):

```bash
# Copy to a writable directory already in your $fpath, e.g.:
sudo cp completions/_devbox /usr/local/share/zsh/site-functions/
# Then reload:
exec zsh
```

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

### Allow-for harvest window

When running unattended agents (LLM tools, scripts) it's useful to let them reach the wider internet for a short time and afterwards see *what* they actually queried, so the allowlist can be informed by reality instead of guesswork. `devbox allow-for` opens a time-bounded window where:

- Domains outside the allowlist are **recorded, not blocked** — DNS resolution succeeds and traffic to those IPs is accepted via a transient `harvest-pool` ipset.
- Domains in the allowlist behave exactly as before — no change in routing.
- When the window closes (timer expires, `--stop`, or `devbox stop` on the container), the firewall is reversed and a harvest log lists every non-allowlist domain that was queried. A clickable desktop notification (Windows toast / Linux notify-send / macOS osascript) opens the log.

```bash
devbox allow-for 30              # 30-minute window in CWD's container
devbox allow-for 30 myapp        # 30-minute window in 'myapp'
devbox allow-for myapp           # Show status (remaining time, captured count)
devbox allow-for --stop          # Close the active window in CWD's container
devbox allow-for --stop myapp    # Close the active window in 'myapp'
```

Harvest logs persist at `/var/log/devbox/allow-for/<container>-<timestamp>.log` on the host (root-owned, tamper-proof from inside the container). See [ADR 0009](docs/adr/0009-allow-for-harvest-window.md) for the security model.

## MCP servers

`devbox mcp` manages [MCP](https://modelcontextprotocol.io) servers for your Containers. Devbox stores an **agent-neutral MCP profile** as its source of truth and *renders* agent-specific config for both Claude Code and Codex from it. Rendered entries are prefixed `devbox-` (e.g. `devbox-context7`) and call a wrapper, `devbox-mcp-run <server>`, instead of the raw command — so devbox keeps a stable control point for the Container-identity check, env validation, and future runtime changes. Re-rendering only ever touches `devbox-` entries; your inherited or hand-added agent MCP entries are never rewritten. See [ADR 0013](docs/adr/0013-container-mcp-profile-and-rendering.md) for the full model.

**v1 supports Container MCP servers only.** A server that runs *inside* the Container (e.g. an `npx`/`uvx`/`docker` launcher) can be imported and launched. **Host MCP servers** — ones that need host credential stores, desktop/OS APIs, browser state, or absolute host paths — are *detected and explained* but **not launched**: crossing that boundary deserves its own design and is deferred.

### Credential isolation

A Container MCP server's secrets are hidden **from the agent**. Servers don't run as your agent user (`node`); they run under a dedicated unprivileged account, `devbox-mcp`, behind an always-on broker. The rendered `devbox-mcp-run <server>` command is a thin **relay**: it connects to the broker as `node`, names the server it wants, and proxies stdio. The broker validates the name against your in-scope profile and spawns the server as `devbox-mcp`, injecting that server's credentials as environment. The agent only ever sees the tool stream — never the credential, because it never becomes the server process and cannot read another UID's `/proc/<pid>/environ`. See [ADR 0014](docs/adr/0014-container-mcp-broker-and-secret-isolation.md).

**Scope of the guarantee — agent, not peers.** This protects secrets from the *agent*, not from *other MCP servers*. All servers share the one `devbox-mcp` UID, and a secret is delivered the only way a server consumes one (an env var), so a server can read a peer server's secret via `/proc/<pid>/environ`. Closing that would need per-server UIDs, which require runtime privilege that [ADR 0003](docs/adr/0003-privileged-entrypoint-no-sudo-in-container.md) deliberately removes — so peer-to-peer isolation is an **accepted non-goal**: treat every Container MCP server you import as sharing one trust domain. Only import servers you'd trust with each other's credentials.

### Onboarding

A fresh interactive install, and the first `devbox update` after MCP support shipped, offer to scan your existing Claude Code / Codex MCP servers for import. The offer fires **once**: it only appears when no devbox MCP profile exists yet *and* you have not already seen or dismissed it. The seen/dismissed marker lives at `~/.config/devbox/mcp/state.json` (outside the profile), so deleting profile files does not re-trigger the prompt. Non-interactive installs and updates never prompt or open a picker — they print a concise follow-up command (`devbox mcp import`) instead. Later updates show only a short reminder.

### Two workflows

**1. Import existing host agent MCP config.** Discovery reads MCP servers already configured in Claude Code / Codex and classifies each candidate (`container` / `host-only` / `unknown`) from evidence — command family, arguments, absolute paths, referenced env-var names, network needs. It is **dry-run by default and writes nothing**:

```bash
devbox mcp import                       # dry-run discovery report (current project + global)
devbox mcp import --all                  # scan every known agent project record
devbox mcp import --project <name-or-path>   # scan one explicit project

# Apply selected Container-safe candidates into the devbox profile:
devbox mcp import --apply                 # interactive wizard (TTY): fzf multi-select,
                                          # per-server scope toggle, project picker
devbox mcp import --apply --server context7
devbox mcp import --apply --import-id imp-abcdef123456
devbox mcp import --apply --all-applicable
```

In a TTY, `import --apply` opens a guided **wizard**: an `fzf` multi-select of the Container-safe candidates (a numbered menu when `fzf` is absent), then per selected server a **scope toggle** (default = the inherited scope; switch project ↔ global in either direction) and — whenever the resulting scope is *project* — a **project picker** (your initialized devbox Projects, with the source project pre-selected). The chosen servers are applied **continue-on-error**: a per-server failure (a secret value that can no longer be recovered, or a candidate that is not Container-applicable) is collected and reported in one final summary, and a single render runs over the servers that did apply. (Two selections that would land in the *same* profile slot — e.g. a global and a project copy of one server both switched to global — are caught up front and the apply is refused so neither silently overwrites the other; the wizard's multi-select otherwise de-duplicates by import id.)

Apply otherwise preserves the source scope (a globally-configured server imports global; a project-scoped one imports for that project) — that stays the only behaviour for the **non-interactive** path (explicit `--server`/`--import-id`/`--all-applicable`, or no TTY), with no prompts. Switching a server's scope copies its secrets to the chosen scope's `0600` store. Inherited secret env *values* can be copied into a scoped secret store; the summary reports which env **key names** were copied, never their values. Host-only, unknown, and excluded (remote/hosted) candidates are shown but not applied. A successful apply auto-renders unless you pass `--no-render`.

**2. Add a brand-new devbox MCP server** that was never in a host agent — `devbox mcp add <name> -- <command spec>` records an explicit new server (distinct from `import`, which discovers inherited ones, and `install`, which materializes runtime). The spec after `--` is the literal launch command:

```bash
devbox mcp add context7 --global -- npx -y @upstash/context7-mcp@latest
devbox mcp add myserver --project myapp -- uvx my-mcp-tool
devbox mcp add gh --global -- docker run -i --rm -e GITHUB_TOKEN=... ghcr.io/github/github-mcp-server
```

The spec is classified and probed like an imported server, so a host-only / unknown / remote-connector command is **refused** with a clear reason rather than recorded. Scope is **always an explicit choice** — `--global` or `--project <p>` set it non-interactively; in a TTY with no scope flag you pick from the same project picker the import wizard uses (global, or any initialized devbox Project, with the current one pre-highlighted); without a TTY and no scope flag, add fails with examples. devbox never silently promotes a new server to global. An inline secret env value (a Docker `-e KEY=VALUE` whose name or value looks like a credential) is written to the scope-correct `0600` secret store and never echoed. A successful add auto-renders unless you pass `--no-render`.

### Profile management

```bash
devbox mcp list                          # effective profile for the current project (global + project)
devbox mcp list --all                    # global plus every project profile
devbox mcp list --inherited              # detected Inherited MCP servers (read-only)
devbox mcp enable  <name> [--global|--project <p>]
devbox mcp disable <name> [--global|--project <p>]   # a project disable of a global server creates a project-only override
devbox mcp remove  <name> [--global|--project <p>] [--purge]   # --purge also deletes scoped secrets
```

A Project entry **shadows** a same-named global entry for that project's effective view. Mutating commands auto-render unless you pass `--no-render`.

### Render

```bash
devbox mcp render --dry-run              # preview the Claude Code / Codex config devbox would write
devbox mcp render --dry-run --project <p>   # focus the preview on one project
devbox mcp render                        # write the full devbox-managed surface into both agents
```

The dry-run preview shows planned `devbox-` entries (their prefixed name and the wrapper command they call — never the raw command, never secret values) and separates existing entries by ownership so the re-render contract is visible. The write path always renders the **full** managed surface (a scoped write would drop other projects' rendered entries).

### Install (materialize)

`import` preserves the inherited command by default (e.g. `npx -y @upstash/context7-mcp@latest`). `devbox mcp install` optionally **materializes** an existing profile entry into persistent Container runtime and rewrites the profile to use the installed command:

```bash
devbox mcp install <name> [--global|--project <p>] [--allow-for <min>] [--keep-window]
```

The install runs **inside a Container** (the runtime lives there, not on the host): a project install targets that project's Container; a global install uses one running Container, offers a picker when several run, and requires `--project` in non-interactive ambiguous cases. npm/npx servers install into the persistent npm-global prefix; Docker-backed servers pull into project-scoped rootless Docker state; Python/uv reports that a dedicated MCP runtime volume is needed first.

Install uses the existing firewall workflow. `--allow-for <min>` opens an [Allow-for window](#allow-for-harvest-window) for the attempt (closed afterward by default so the harvest log is produced immediately; `--keep-window` leaves it open). On a blocked-network failure the command points at `devbox blocked` and shows the exact rerun command — so you can review blocked domains, allow the trusted ones, and rerun the same install.

### Doctor

```bash
devbox mcp doctor                        # diagnose profile / render / runtime problems
devbox mcp doctor --fix                  # apply only SAFE local fixes
```

Doctor checks host-vs-Container context, the `devbox-mcp-run` wrapper on PATH, profile JSON validity, render drift (profile vs rendered config), and required env presence (by name only). `--fix` performs only safe local fixes — re-render, create missing MCP dirs, repair the wrapper symlink. It never installs packages, allows domains, purges runtime, or enables host-only servers.

Run `devbox mcp --help` for the full subcommand reference.

## Agent-browser

`devbox agent-browser` gives an LLM agent inside the container a real Chrome on the host to drive — screenshots of the project's dev URL, JS console output, network-tab inspection, click-through flows. The **Host agent Chrome** runs under a dedicated `devbox-agent` OS user with hardened launch flags; the container reaches its CDP endpoint through an **Agent-browser session bridge** (a per-session socat process inside the container's network namespace). All of Chrome's outbound HTTP/HTTPS is forced through the **Agent-browser proxy** that mirrors the firewall's default-deny posture at the browser layer. See [ADR 0010](docs/adr/0010-agent-browser-host-broker-and-proxy.md) for the full security model and the **Agent-browser** section of [CONTEXT.md](CONTEXT.md) for the terminology.

### Quick start

A full session from launch to teardown, including a short network window for one external request:

```bash
# Host: launch Host agent Chrome + per-session bridge into the 'my-app' container
devbox agent-browser start my-app

# Container: drive Chrome via the agent-browser CLI (dev URLs go through the
# Chrome bypass list — no network window needed)
agent-browser navigate http://3000.my-app.test
agent-browser screenshot --output /tmp/dash.png

# Host: open a 5-minute Agent-browser network window (proxy flips to harvest
# mode) so Chrome can reach a host that isn't a dev URL and isn't in the
# Agent-browser allowlist
devbox agent-browser allow-for 5 my-app

# Container: that external navigation can now succeed
agent-browser navigate https://developers.facebook.com/tools/debug/

# Host: close the window early (or let the timer expire) and tear down the session
devbox agent-browser allow-for --stop my-app
devbox agent-browser stop my-app

# Host: any time during the session, inspect status
devbox agent-browser status my-app       # active session + remaining network-window time
```

### Two time gates

`agent-browser` has two independent time gates. The **Agent-browser session** is the Chrome+bridge lifecycle and can run for hours (the Chrome window on your desktop is the visual audit surface). The **Agent-browser network window** is a short sub-state that flips the proxy from default-deny into harvest mode, paralleling the firewall `allow-for` on the browser layer.

| Layer | Window | Started by | Closed by | Default |
|---|---|---|---|---|
| Firewall (DNS + iptables) | Allow-for window | `devbox allow-for N` | `--stop`, timer, container stop | closed |
| Agent-browser (HTTP proxy) | Agent-browser session | `devbox agent-browser start` | `... stop`, idle timeout, container stop | absent |
| Agent-browser (HTTP proxy) | Agent-browser network window | `devbox agent-browser allow-for N` | `... allow-for --stop`, timer, session stop | closed |

Dev URLs (`localhost`, `*.test`, `*.127.0.0.1.sslip.io`) are set as Chrome's `--proxy-bypass-list` and go direct without touching the proxy — opening a network window is only needed for genuinely external hosts.

```bash
devbox agent-browser allow-for 15 my-app   # 15-minute window in 'my-app'
devbox agent-browser allow-for --stop my-app   # close the window early
```

### Default-deny and growing the allowlist

The Agent-browser proxy reads its allowlist from `~/.config/devbox/agent-browser-allowed-domains.conf` (distinct from the firewall allowlist). Format: one domain pattern per line, `#` for comments, `*` glob for subdomains.

```bash
# devbox agent-browser default-mode allowlist
*.github.com
api.openai.com
registry.npmjs.org
```

The installer drops a documented `agent-browser-allowed-domains.conf.example` next to it on first run. Edits take effect on the next `devbox agent-browser start`; mid-session reloads happen automatically when you run `devbox agent-browser allow-for ...` (the broker re-stages the snapshot and SIGHUPs the proxy). Hosts that show up in a window's harvest log are good candidates for promotion to the durable list.

### Artefacts

Each session leaves three files on the host, owned by `devbox-agent:devbox-agent` mode `0640` — your user reads them via group membership; nothing inside the container can write to them.

```
/var/log/devbox/agent-browser/<container>-<ISO>.netlog.json    # Chrome's native netlog
/var/log/devbox/agent-browser/<container>-<ISO>.proxy.log      # JSONL of every proxy decision
/var/log/devbox/agent-browser/<container>-<ISO>.summary.md     # human-readable digest
```

`summary.md` lists visited hosts, out-of-allowlist hits during harvest, denied requests, and any hard fails (`file://`, `chrome://`, native messaging, denied downloads). A clickable desktop notification at session and network-window close opens the relevant file.

### Per-OS prerequisites

Chrome must be installed on the host. The **Agent-browser proxy** + **Host agent Chrome** + notification dispatcher each have an OS-specific path, all gated through `lib/host-platform.sh`.

#### WSL2 (validated)

The reference platform. Chrome runs as a Linux binary inside the WSL2 distro — *not* the Windows Chrome on the host. WSLg renders the window onto the Windows desktop, so the visual-audit story is identical to native Linux.

Setup checklist:

1. Install Chrome (or Chromium) inside the WSL2 distro:
   ```
   sudo apt-get install -y chromium                          # Debian/Ubuntu
   # or Google Chrome:
   wget -qO- https://dl.google.com/linux/linux_signing_key.pub | sudo gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg
   echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" | sudo tee /etc/apt/sources.list.d/google-chrome.list
   sudo apt-get update && sudo apt-get install -y google-chrome-stable
   ```
2. Run `bash install.sh` (or `devbox update` if upgrading) — this creates the `devbox-agent` OS user + group, adds you to that group, and stages the Python helpers under `/usr/local/lib/devbox/agent-browser/`.
3. **Re-login (or `newgrp devbox-agent`)** so the group membership applies in your current shell. Without this, you cannot read `summary.md` / netlog / proxy log artefacts at `/var/log/devbox/agent-browser/` (mode `0640`, group-readable only).
4. Notifications use the existing **allow-for** toast pipeline (BurntToast via `powershell.exe`). No extra setup beyond what `devbox allow-for` already needed.

Common WSL2 gotchas:

- **`chromium` from snap** doesn't work cleanly with `--user-data-dir` under `/var/lib/devbox-agent/`. Use the apt or .deb-distributed binary.
- **WSLg not rendering**: requires WSL version `0.65.1+` and a Windows 11 / Windows 10 22H2+ host. Run `wsl --version` on the Windows side to check.
- **`host.docker.internal` resolution**: Docker Desktop sets this automatically; on Docker-CE-inside-WSL2 (no Docker Desktop), `docker-run.sh` passes `--add-host=host.docker.internal:host-gateway` so the in-container socat bridge can still reach the host-side Chrome.

#### Native Linux + macOS

Both platforms are designed-for but not yet end-to-end validated by the maintainer. The platform-dispatch helper (`lib/host-platform.sh`) covers the differences.

**Native Linux** (Ubuntu, Arch, Fedora, openSUSE, Alpine):

1. Install Chrome via your package manager:
   ```
   sudo apt-get install -y chromium                # Debian/Ubuntu
   sudo dnf install -y chromium                    # Fedora/RHEL
   sudo pacman -S chromium                         # Arch
   sudo zypper install chromium                    # openSUSE
   sudo apk add chromium                           # Alpine
   ```
   …or Google Chrome from `https://www.google.com/chrome/`.
2. `bash install.sh` (same as WSL2).
3. **Re-login (or `newgrp devbox-agent`)** to pick up the group.
4. Make sure `notify-send` (`libnotify-bin` / `libnotify`) is installed for click-to-open toasts.

**macOS:**

1. Install Chrome to `/Applications/`:
   ```
   brew install --cask google-chrome
   ```
   …or download from `https://www.google.com/chrome/`.
2. `bash install.sh`. `sysadminctl` will prompt for an administrator password (GUI dialog) the first time — used to create `devbox-agent` and the matching `devbox-agent` group, and to bind your user to it.
3. **Open a new terminal session** so the new group membership is picked up.
4. Toast click-to-open uses `osascript`; no extra install.

Full per-OS validation is pending — see ADR 0010 § "Cross-platform abstraction".

## Port Routing

Devbox uses a shared Traefik reverse proxy to route HTTP traffic to containers by hostname.

```bash
devbox port 3000                 # Expose port 3000 on all containers
devbox ports                     # List active routes
```

Each route is published under two hostnames simultaneously, so both work from any browser at the same time:

| Mode | URL for `devbox port 3000` in project `my-app` |
|------|----------------------------------------------|
| `local` (default) — `.test` resolved by a local dnsmasq container | `http://3000.my-app.test` |
| `external` (fallback) — `.sslip.io` wildcard DNS | `http://3000.my-app.127.0.0.1.sslip.io` |

URLs flip to `https://` after `devbox dns-install --enable-https` (see [HTTPS](#https-mkcert-signed-leaf-certs) below). Both hostnames serve the same cert; HTTP requests on `:80` are 301-redirected to HTTPS.

Default ports (3000, 5173, 8080, etc.) are applied automatically on container start. The list is stored in `~/.config/devbox/default-ports.conf` and can be edited.

### One-time host resolver setup for `.test`

`.test` is an [RFC 2606](https://www.rfc-editor.org/rfc/rfc2606) reserved TLD; the host OS needs to be told to route `*.test` to `127.0.0.1`. `devbox dns-install` handles that for you per OS:

```bash
devbox dns-install               # auto: try local, fall back to external on conflict
devbox dns-install --local       # force local; fail loud if setup fails
devbox dns-install --external    # skip resolver setup, use sslip.io URLs only
devbox dns-status                # show current mode + resolver state + verify
devbox dns-uninstall             # remove resolver config + dns.conf
```

What `--auto` does per platform (all are idempotent; sudo / UAC prompts as needed):

| Platform | Resolver setup |
|----------|----------------|
| macOS | writes `/etc/resolver/test` (per-TLD nameserver = `127.0.0.1`) |
| Linux + systemd-resolved | drop-in `/etc/systemd/resolved.conf.d/devbox.conf` (`DNS=127.0.0.1`, `Domains=~test`) |
| Linux + NetworkManager-dnsmasq | drop-in `/etc/NetworkManager/dnsmasq.d/devbox.conf` (`server=/test/127.0.0.1`) |
| WSL2 | both of the above for the WSL2-side CLI, **plus** a Windows NRPT rule (`Add-DnsClientNrptRule -Namespace .test -NameServers 127.0.0.1`) via UAC-elevated PowerShell so the Windows browser resolves too |

Mode preference is persisted in `~/.config/devbox/dns.conf`. Switching mode (`devbox dns-install --external`) only flips which URL `devbox port` and `devbox ports` print — Traefik keeps accepting both forms.

### HTTPS (mkcert-signed leaf certs)

Opt-in HTTPS for every project, signed by a per-host [mkcert](https://github.com/FiloSottile/mkcert) root CA installed once into the OS + browser trust stores. One UAC / sudo / Touch ID prompt per machine for the entire lifetime; zero prompts per project (leaf certs are signed locally). See [ADR 0008](docs/adr/0008-https-via-mkcert-graceful-degradation.md).

```bash
devbox dns-install --enable-https    # install CA, flip https.conf active=true, migrate live routes
devbox dns-install --disable-https   # revert to HTTP-only (CA stays installed)
devbox dns-install --purge-ca        # remove CA from all trust stores + delete https.conf
devbox dns-status                    # includes HTTPS section: active, CA fingerprint, cert inventory
```

What `--enable-https` does:

1. Runs `mkcert -install` on the native trust store (Linux NSS / macOS Keychain / WSL2-distro NSS).
2. **WSL2 only:** installs the CA into the Windows `LocalMachine\Root` store via UAC-elevated `certutil.exe`, and merges `ImportEnterpriseRoots=true` into Firefox's `policies.json` if Firefox is installed (org-managed policies are preserved).
3. Flips `~/.config/devbox/https.conf` `active=true`.
4. Rewrites every running project's Traefik route YAML from `web` → `websecure` (each original is backed up as `<name>.yml.pre-https-backup`).
5. Recreates `devbox_traefik` with `--entrypoints.websecure.address=:443` + permanent 301 from `:80` → `:443`.

Per-project leaf certs land under `~/.config/devbox/certs/<project>.{pem,key,meta}` on the first `devbox <project>` call after enabling. Certs auto-regenerate when: meta is missing, expiry is within 10 days, the root CA fingerprint changed (e.g. user ran `mkcert -uninstall` manually), or the SAN set drifted (DNS mode / external provider change).

If `devbox update` finds no `https.conf` it offers a one-shot upgrade prompt. Decline with `n` and devbox persists `optout=true`; subsequent updates will not ask again until you explicitly run `devbox dns-install --enable-https`.

#### Troubleshooting HTTPS

- **Port 443 already in use at `--enable-https` time** — devbox refuses to flip `active=true` and prints the offending PID/comm. Free the port (or remap the conflicting process) and rerun. `https.conf` is left untouched so `devbox update` keeps offering the prompt.
- **Port 443 grabbed between sessions** — `bootstrap_traefik` downgrades the next Traefik start to HTTP-only and warns. URLs continue to advertise `http://` (`devbox::url_scheme` keys off the running Traefik, not the persisted opt-in). Stop the conflicting process and `devbox stop && devbox` to recover.
- **UAC declined on WSL2** — `--enable-https` persists `optout=true` and stays HTTP-only. Rerun the command to retry (UAC fires again).
- **Manual `mkcert -uninstall`** — the CA fingerprint stored in each cert's `.meta` no longer matches the freshly-seeded CA. `ensure_project_cert` detects the drift on the next `devbox <project>` and regenerates every leaf. Run `--enable-https` again to re-install the new CA.
- **`devbox dns-status` HTTPS section** — shows `active`, `optout`, CA fingerprint (`sha256:...`), trust-store platforms (`linux,windows,macos`), and the project-cert inventory with the nearest expiry date.
- **Removing the CA on uninstall** — `devbox uninstall --purge-ca` (or interactive `y` at the `Remove local CA from system trust stores? [y/N]` prompt) runs `mkcert -uninstall` natively, removes the CA from the Windows Root store + Firefox policy on WSL2, deletes `https.conf`, and removes the mkcert CAROOT directory. Default `n` keeps the CA in place because it may be shared with non-devbox mkcert setups.

### Troubleshooting

- **Port 80 already in use** — `devbox` aborts with `pid <N> (<comm>)` of the offender before starting Traefik. Stop that process (or remap its port) and re-run.
- **Port 53 already in use** — `dns-install --auto` falls back to `external` mode and tells you why. Stick with sslip.io URLs, or stop the conflicting resolver and re-run `dns-install --local`.
- **Tailscale Magic DNS** — `accept-dns=true` takes over `/etc/resolv.conf` and bypasses `.test` routing. Either disable Magic DNS, add `.test` as a split-DNS exception, or fall back to `external` mode.
- **Corporate VPN with DoH/strict DNS** — same shape as Tailscale; `external` mode skips the host resolver entirely and works through the VPN.
- **`.test` doesn't resolve after install** — run `devbox dns-status` to see whether dnsmasq is up, whether the per-OS resolver drop-in is in place, and whether a probe `getent hosts devbox-probe.test` returns `127.0.0.1`.
- **Coming from `traefik.me`** — `devbox update` auto-rewrites every dynamic route file under `~/.config/devbox/traefik/dynamic/` to the dual-`Host()` form and runs `dns-install` if `dns.conf` is missing. No manual edits needed; see ADR 0007 for the migration design.

## Multi-session

Multiple devbox containers can run simultaneously for different projects. Each gets its own:

- Container (`devbox-<project>`)
- Docker volume (`devbox-<project>-docker`)
- Shell history volume (`devbox-<project>-history`)
- Claude config volume (`devbox-<project>-claude`)
- Traefik port routes (namespaced by project name)

Shared across all containers:
- Neovim data volume (`devbox-nvim-data`)
- Global npm packages volume (`devbox-npm-global`) — `npm install -g` persists across restarts
- Cursor server volume (`devbox-cursor-server`)
- VS Code server volume (`devbox-vscode-server`)
- Firewall allowlist (`~/.config/devbox/allowed-domains.conf`)
- Host `~/.claude/` directory (read-only, for user-level `CLAUDE.md`)
- Host `~/.config/git/ignore` (global gitignore)
- Traefik proxy (`devbox_traefik`) and DNS resolver (`devbox_dns`) shared infra

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
| `NTFY_TOKEN` | ntfy.sh notification token (auto-detected from `~/.claude/hooks/*.sh` on host) |
| `NTFY_URL` | ntfy.sh topic URL for Claude hook notifications (auto-detected from `~/.claude/hooks/*.sh` on host) |
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

#### Windows shutdown hook

When Windows shuts down or restarts, WSL2 is terminated abruptly without sending SIGTERM to processes inside. This causes containers to exit with code 255 instead of a clean shutdown.

To fix this, install the Windows shutdown hook that stops all Docker containers **before** WSL2 terminates:

```powershell
# Run as Administrator in PowerShell
powershell -ExecutionPolicy Bypass -File scripts\windows\install-shutdown-hook.ps1
```

This registers a shutdown script via the Windows registry (works on Home edition without `gpedit.msc`). The script runs automatically during shutdown, stops all running containers in parallel with a 15s timeout, and logs to `C:\Scripts\devbox\shutdown.log`.

To uninstall:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\windows\uninstall-shutdown-hook.ps1
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

Images older than 24 hours are cleaned up automatically on each invocation.

### WezTerm keybinding

Add a keybinding to your `~/.wezterm.lua` so `Ctrl+Shift+S` grabs the clipboard image and pastes its path into the terminal. This snippet auto-detects WSL vs native Linux:

```lua
{
  key = "s",
  mods = "CTRL|SHIFT",
  action = wezterm.action_callback(function(window, pane)
    local cmd
    if wezterm.target_triple:find("windows") then
      -- Windows/WSL: call script via wsl.exe (default distro)
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


### WezTerm tab duplication and tab title

OSC 7 (`\033]7;file://host/path`) is the standard way to report CWD to terminals, but **it doesn't work on WezTerm's WSL domain** — `pane.current_working_dir` stays nil. OSC 0 doesn't work either. Only **OSC 1** (`\033]1;TITLE`) works for setting the tab title on WSL.

Inside devbox containers, OSC 7 *does* work (escape sequences pass through docker to WezTerm). The container hostname (`docker run --hostname "$PROJECT_NAME"`) appears as `cwd.host` in WezTerm, which is used for the project name prefix.

The solution is a hybrid approach in `~/.zshrc` (managed by chezmoi):
- **Container**: OSC 7 with hostname for `cwd.host` tab prefix + `HOST_HOME` as safe CWD
- **Host WSL**: OSC 1 to set tab title directly to CWD basename

```bash
if [ -n "$DEVCONTAINER" ]; then
    # Devbox: OSC 7 with hostname for tab title prefix (cwd.host in WezTerm).
    # HOST_HOME as safe CWD so new tabs open in host's ~ instead of /workspace.
    # OSC 1 sets pane.title to CWD basename (updates on cd, restores after Claude Code exit).
    __wezterm_osc7() {
        printf '\033]7;file://%s%s\033\\' "${HOSTNAME}" "${HOST_HOME:-/}"
        printf '\033]1;%s\033\\' "${PWD##*/}"
    }
    precmd_functions+=(__wezterm_osc7)
else
    # Host WSL: OSC 7 doesn't set cwd, but empty OSC 7 clears stale cwd.host
    # left over from a previous container session. OSC 1 sets the tab title.
    __wezterm_title() {
        printf '\033]7;\033\\'
        printf '\033]1;%s\033\\' "${PWD##*/}"
    }
    precmd_functions+=(__wezterm_title)
fi
```

In `~/.wezterm.lua`, use `CurrentPaneDomain` for both the keybinding and the `+` button:

```lua
{ key = 'T', mods = 'CTRL|SHIFT', action = act.SpawnTab('CurrentPaneDomain') },
```

```lua
wezterm.on('new-tab-button-click', function(window, pane)
  window:perform_action(act.SpawnTab('CurrentPaneDomain'), pane)
  return false
end)
```

Claude Code continuously overwrites the terminal tab title via OSC escape sequences (spinner animation during work, "Claude Code" as static title). There is no official config to disable this ([#7229](https://github.com/anthropics/claude-code/issues/7229)). The `format-tab-title` event controls what WezTerm **displays** in the tab bar. On WSL host tabs, `pane.title` is set to CWD basename by the OSC 1 precmd hook above. On devbox tabs, `cwd.host` carries the project name from OSC 7. Add to `~/.wezterm.lua`:

```lua
wezterm.on('format-tab-title', function(tab)
  local pane = tab.active_pane
  local cwd = pane.current_working_dir

  -- pane.title defaults to "wslhost.exe" on WSL — treat as unset
  local title = pane.title or ''
  if title:find('wslhost') then
    title = ''
  end

  -- Devbox container: cwd.host = project name (--hostname flag)
  if cwd and cwd.host ~= '' then
    if title ~= '' then
      return ' ' .. cwd.host .. ': ' .. title .. ' '
    end
    return ' ' .. cwd.host .. ' '
  end

  -- Host WSL: pane.title is set to CWD basename via OSC 1 precmd hook
  -- (OSC 7 doesn't work on WezTerm WSL domain, so cwd is always nil here)
  return title ~= '' and (' ' .. title .. ' ') or ' shell '
end)
```

Result:
- Host tab: CWD basename (e.g. `Projekty`) via OSC 1, updates on every `cd`.
- Devbox tab (shell): `myapp` — project name from container hostname.
- Devbox tab (Claude Code): `myapp: Claude Code` — project prefix + Claude Code title.
- After exiting Claude Code: `myapp` (back to project name only).
- After exiting devbox: CWD basename (host precmd clears stale `cwd.host` via empty OSC 7).
- New tab from devbox pane: opens in host's home directory (`HOST_HOME`).

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
├── lib/
│   └── allowlist.sh                # Firewall allowlist module (sourced by host + container)
├── docs/
│   └── adr/                        # Architecture decision records
├── completions/
│   └── _devbox                     # Zsh completion script
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
