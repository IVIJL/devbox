# ADR 0014 — Container MCP broker and secret isolation

- **Status:** proposed
- **Date:** 2026-05-30
- **Builds on:** ADR 0003 (privileged entrypoint, no sudo / no setuid from inside
  the container), ADR 0010 (Agent-browser host broker pattern), ADR 0013
  (Container MCP profile and rendering)

## Context

ADR 0013 introduced an agent-neutral **MCP profile**, a secret store, render of
`devbox-`-prefixed agent entries that call a `devbox-mcp-run` wrapper, and the
wrapper itself which "loads devbox's canonical MCP profile" inside the
**Container**. Issues 01–13 shipped all of that.

End-to-end testing inside a real **Container** surfaced two gaps that meant a
`devbox`-managed MCP server never actually ran inside the **Container**:

1. **The canonical profile and secret store never reach the Container.**
   `docker-run.sh` bind-mounts `~/.claude` and `~/.codex`, but devbox's own
   config tree `~/.config/devbox` is host-only by design and is not mounted.
   The wrapper resolves the profile at `~/.config/devbox/mcp/profile.json`
   (= `/home/node/.config/devbox/mcp/...` in-container), which does not exist
   there. No `XDG_CONFIG_HOME` is passed in and no startup step seeds it, so
   every `devbox-` MCP server fails to connect. The plan assumed the wrapper
   "loads the canonical profile" without ever specifying how the profile crosses
   the host → container boundary.

2. **Render writes to the wrong file for the Container.** The Container reads
   `~/.claude/.claude.json` (`CLAUDE_CONFIG_DIR=/home/node/.claude`, bind-mounted),
   but on the host `default_config_path()` prefers the host-native `~/.claude.json`,
   so rendered `devbox-` entries land where the Container never reads them.

Beyond fixing reachability, a security requirement was raised: **the agent
(Claude Code / Codex, running as `node`) must not be able to read MCP server
credentials.** Two hard facts constrain the solution:

- Inside the **Container** every process runs as `node` (UID 1000). A process's
  `/proc/<pid>/environ` is mode `0400` owned by its UID, so any `node` process
  can read another `node` process's environment. If an MCP server runs as `node`,
  the agent can steal its API key from `/proc`. **Same-UID isolation is
  impossible** — credentials can only be hidden by running the server under a
  different UID.
- A plain RO bind-mount carries the host's numeric UID (host `vlcak` UID 1000 →
  container `node`), and a `0600` host file is then readable by `node` and *not*
  by any other in-container UID. **A bind-mount cannot grant "readable by the
  server account but not by the agent."**
- ADR 0003 forbids NOPASSWD sudoers entries and setuid bridges and guarantees
  "no path back to root from inside the container." `node` therefore cannot
  switch UID on its own, so it cannot launch a process under a different account.

## Decision

### Profile reaches the Container via a live read-only bind-mount

The **MCP profile** is secret-free (it stores references, not credential
values). It is delivered into the Container by a read-only bind-mount of the
host MCP store, mirroring devbox's established host → container shared-state
pattern (traefik dynamic config, dnsmasq conf, the firewall allowlist, the host
gitignore). Because it is a live mount, `enable` / `disable` / `add` / `import`
of a server take effect for the next agent session with no restart. The mount
is read-only so the Container cannot corrupt host state.

### MCP servers run as a dedicated `devbox-mcp` account behind an always-on broker

Credentials are hidden from the agent by running every **Container MCP server**
under a dedicated unprivileged service account, `devbox-mcp`, distinct from the
agent user `node`. Because `node` cannot change UID (ADR 0003), it cannot start
that process itself. Instead:

- The entrypoint **root phase** starts a long-running **MCP broker** as
  `devbox-mcp` before the `setpriv` drop to `node`. The drop must reset the full
  credential set, not just the UID:
  `setpriv --reuid devbox-mcp --regid devbox-mcp --init-groups … &`. `--reuid`
  alone leaves the broker with root's GID and supplementary groups — for a
  component whose entire purpose is credential isolation, retained root-group
  membership would re-expose group-readable root-owned files and weaken the
  `devbox-mcp`-only boundary. `--regid devbox-mcp --init-groups` sets the
  primary group to `devbox-mcp` and reinitializes supplementary groups from
  `/etc/group` for that account, so the broker holds only `devbox-mcp`'s own
  group memberships. The broker is then owned by `devbox-mcp`, so `node` can
  neither signal nor ptrace it.
- The broker **always runs**, even with an empty profile, so a server added to a
  running Container is serviceable without a restart (the profile is a live
  mount).
- Rendered agent config keeps calling `devbox-mcp-run <server>`, but that command
  is now an **MCP relay**: it runs as `node`, connects to the broker's unix
  socket, names the server it wants, and proxies stdio. The broker validates the
  name against the in-scope profile and **spawns a fresh server process as
  `devbox-mcp` on demand**, injecting that server's secrets as environment. The
  agent only ever sees the stdio tool stream — never the credential.

This is the Agent-browser broker pattern (ADR 0010) applied in-container: cross a
trust boundary without handing the untrusted side the credentials.

### Secrets are delivered by a root-staged private copy

A bind-mount cannot give `devbox-mcp`-only read access (UID-mapping, above), so
secrets are staged instead of mounted into a node-readable path:

- The host secret store is bind-mounted read-only under a **root-only** directory
  (mode `0700`, owned root) that `node` cannot traverse.
- The entrypoint root phase copies the in-scope secrets into a **`devbox-mcp`-private
  tmpfs** (`/run/devbox-mcp/…`, dir `0700` `devbox-mcp`, file `0400` `devbox-mcp`).
  `node` can read neither the source (root-only dir) nor the copy (devbox-mcp-only
  dir). Root can; that is accepted. tmpfs keeps secrets off disk and clears them on
  container stop.
- The broker re-reads the staged secrets file on every spawn, so it is stateless
  between sessions.

The broker's unix socket lives in a node-connectable location separate from the
`0700` secret directory (connecting to the socket exposes no credential, only a
stdio pipe).

### Scope: global + current Project, with least-privilege secret staging

A Container is one **Project**; its effective profile is `global + this Project`
(CONTEXT.md). The broker serves global servers plus this Container's Project
servers, resolved from **Container identity**. Secret staging is least-privilege:
only global secrets and *this* Project's secrets are staged; a Container for
Project A never receives Project B's secrets.

### Render target is the Container-visible config

Discovery and rendering are split: `import` reads the host config via
`default_config_path()` (correct for finding what the user has), but render always
writes `devbox-` entries to the **Container-visible** `~/.claude/.claude.json`,
regardless of whether host `~/.claude.json` exists. This makes the entries appear
in the Container and keeps the host's own Claude config free of container-only
entries (the relay has no broker to reach on the host). Render still touches only
`devbox-`-prefixed keys, so other shared config is untouched. Codex has no drift
(`~/.codex` is mounted whole at the same relative path).

### Live updates: profile via mount, secrets via an explicit `devbox mcp reload`

Profile changes are live via the mount. Secret changes (a value copied by
`import`/`add`, or a rotation) need a re-stage, which requires root. Rather than a
persistent in-container root watcher — which would reintroduce exactly the
residual-root surface ADR 0003 removes — re-staging is **host-initiated**:

- A new host command `devbox mcp reload` re-stages secrets into the running
  in-scope Container(s) via a momentary `docker exec -u 0` (same trust level as
  starting the Container). No `devbox stop` / `start` needed.
- After a secret-writing command, if a relevant Container is running, the CLI
  **detects and prompts**: it reports that secrets were staged on the host and
  that `devbox mcp reload` will load them into the running Container.
- Inherent limit (shared with a full restart): a re-stage affects only
  **subsequently spawned** servers — a running process keeps its environment.
  "Live" means "the next session gets the new secret without a Container restart."

## Considered options

- **Scoped setuid launcher (node → devbox-mcp).** A setuid-to-unprivileged-account
  binary the agent runs. Far less code than a broker, grants no root. Rejected:
  it reintroduces a setuid bridge, softening ADR 0003's "no setuid bridges"
  invariant, which we will not weaken; setuid binaries are also a classic footgun.
- **In-container inotify root watcher for live secrets.** A root daemon that
  re-stages on change. Rejected: a persistent root process is precisely the
  residual-root attack surface ADR 0003 eliminates.
- **Bind-mount the secret store directly.** Rejected: UID-mapping makes a host
  `0600` file readable by `node` and unreadable by `devbox-mcp` — the opposite of
  what is needed.
- **Seed the whole profile by copy at startup.** Rejected for the (secret-free)
  profile: a live RO mount is simpler, has no sync drift, and is the established
  pattern. Copy-staging is used only where ownership semantics force it: secrets.
- **Mount `~/.config/devbox` into the Container.** Rejected: devbox's host
  orchestration config does not belong inside the Container. Only the MCP subset
  crosses, and secrets cross only as a re-permissioned private copy.

## Consequences

- A new `devbox-mcp` Container account is added (Dockerfile), with its own HOME and
  a writable npm/npx cache so on-demand `npx` servers run under it; materialized
  runtime (ADR 0013 `install`) must remain executable by `devbox-mcp`.
- New runtime components: the broker (started in the entrypoint root phase) and the
  relay (the reworked `devbox-mcp-run`). The broker is **agent-neutral** — both the
  Claude Code and Codex relays connect to the same broker.
- The wrapper's behavior shifts from "exec the server directly" (ADR 0013) to
  "relay stdio to the broker"; the rendered command name is unchanged, preserving
  ADR 0013's stable control point.
- Secret rotation requires `devbox mcp reload` (or a restart) to reach a running
  Container; it never auto-propagates to already-running server processes.
- ADR 0003's invariants are preserved unchanged: no NOPASSWD sudoers, no setuid
  bridges, no persistent or residual root inside the Container.
