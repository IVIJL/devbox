# ADR 0013 — Container MCP profile and agent-specific rendering

- **Status:** proposed
- **Date:** 2026-05-26

## Context

Devbox users increasingly configure MCP servers in their host agents.
Those configurations are already visible inside devbox containers because
the agent config trees are shared:

- `~/.claude` is bind-mounted read-write into every **Container**.
- `~/.codex` is bind-mounted read-write into every **Container**.
- `~/.agents` is bind-mounted read-only when present.

Local inspection confirmed this is not theoretical: Claude Code has MCP
state in `~/.claude/.claude.json` and
`~/.claude/mcp-needs-auth-cache.json`, and user settings can enable all
project MCP servers. An MCP entry defined on the host may therefore be
launchable from inside a **Container** today.

That visibility is useful, but it is not enough to make an MCP server safe
or correct inside devbox. The same command can mean different things on
host and in container:

- absolute host paths may not exist in the **Container**;
- Windows and WSL2 paths may refer to the wrong OS boundary;
- host credential stores, desktop state, browser state, clipboard, and
  OS APIs are intentionally outside the **Container** boundary;
- container-side network access is governed by the firewall **Allowlist**
  and **Allow-for window**, while host-side processes are not;
- package launchers such as `npx`, Python/uv, and Docker may need runtime
  installation and cache persistence.

The first version should support useful MCP servers inside the container,
without accidentally turning every visible host MCP definition into a
devbox capability.

## Decision

### Support only Container MCP servers in the first version

The first implementation supports **Container MCP servers** only.
**Host MCP servers** are detected and explained, but devbox does not launch
or bridge them by default.

Host-side MCP support is deferred to a future design with its own launcher,
bridge, lifecycle, and audit model, likely following the shape of
Agent-browser (ADR 0010). This keeps the first version aligned with the
existing **default-deny** container security model.

### Discover inherited MCP, but import via classification

Devbox discovers **Inherited MCP servers** from existing agent
configuration. Discovery does not trust or enable them by itself.

Discovery is provider-based rather than hardwired to one agent. The first
providers are Claude Code and Codex. Future providers can cover Cursor, PI,
`.mcp.json` variants, or other agent config sources by normalizing their
records into the same inherited-candidate shape.

`devbox mcp import` defaults to dry-run and reports, for each candidate:

- detected source;
- recommended placement (`container-safe`, `host-only`, or `unknown`);
- missing runtime, environment, or network prerequisites;
- proposed action.

Only an explicit apply step adds a server to a devbox **MCP profile**.

The classifier uses evidence rather than names alone: command family
(`npx`, `uvx`, `python`, `docker`, absolute binary), arguments, absolute
paths, referenced environment variables, desktop/OS dependencies, network
requirements, and dry-run probes.

### Store an agent-neutral MCP profile

Devbox stores MCP state in an agent-neutral canonical profile, then renders
agent-specific configuration for Claude Code and Codex.

The effective **MCP profile** is formed from user-global MCP choices plus
Project-specific MCP choices. Project choices are stored in user-local
devbox state, not in the repository, because MCP choices are personal and
often depend on credentials, host tools, and workflow preferences.

Import preserves the source scope where it can be determined: globally
configured inherited MCP servers import as global candidates, and
Project-scoped inherited MCP servers import as Project candidates. Adding a
new MCP server requires an explicit scope decision through a flag or prompt;
devbox does not silently promote new servers to global.

### Render devbox-managed agent entries

Devbox renders only entries it owns:

- rendered MCP server names use a `devbox-` prefix, for example
  `devbox-context7`;
- re-rendering removes or replaces stale devbox-managed entries only;
- inherited or manually added agent MCP entries are never rewritten;
- `devbox mcp doctor` shows inherited entries separately from
  devbox-rendered entries.

Rendered config lives in the host bind-mounted Claude Code and Codex config
trees in the first version. This makes the effective state visible to users
and available to agents started inside the **Container**. Because the same
trees are also visible on the host, rendered commands must be devbox-aware
and fail clearly when invoked outside a **Container**.

### Render wrapper commands, not raw MCP commands

Agent-specific config does not call the raw MCP command directly. It calls a
devbox wrapper, for example:

```sh
devbox-mcp-run context7
```

The wrapper:

- checks **Container identity**;
- loads devbox's canonical MCP profile;
- validates runtime and environment prerequisites without logging secret
  values;
- launches the current command for that server;
- fails clearly if invoked on the host.

This lets devbox later change a server from `npx` to a persistent local
binary without rewriting every agent-specific config entry.

### Preserve imported commands by default; materialize optionally

Import preserves the inherited command spec by default, such as:

```sh
npx -y @upstash/context7-mcp@latest
```

Users can choose a later materialization step that installs the server into
persistent runtime state and updates the canonical profile to use that
installed command.

Runtime persistence follows profile scope:

- global MCP profile entries install into shared runtime state when safe;
- Project MCP profile entries install into Project-scoped runtime state;
- Docker-backed MCP servers default to Project-scoped runtime state.

Existing persistent locations are preferred first: the shared npm-global
volume for npm tools and the per-project rootless Docker volume for Docker
state. Python/uv persistence should use a clean existing location if one is
available; otherwise a dedicated MCP runtime volume is preferable to hiding
state inside an unrelated mount.

MCP installation uses the existing firewall workflow. The user can open an
**Allow-for window** before installation, or let the first attempt populate
blocked domains, review them via `devbox blocked`, allow trusted domains,
and rerun the same install command.

## Considered options

### Blindly reuse host agent MCP config

Rejected. It is convenient, but a host MCP definition is not automatically
safe inside a **Container**. Absolute paths, credentials, desktop access,
Windows/WSL2 boundaries, and host network assumptions can all be wrong.

### Write directly into Claude Code's MCP state

Rejected as the source of truth. Claude Code already has visible MCP state,
but devbox needs cross-agent behavior and placement classification. Storing
only Claude-native state would make Codex support and future migration
harder.

### Put default MCP choices in the project repository

Rejected for the first version. MCP selection is user-specific and often
credential-specific. Repositories should not gain default MCP servers merely
because one developer uses them.

### Launch Host MCP servers through a bridge in v1

Rejected for the first version. This is a real security boundary crossing
and deserves a separate design. Host-only servers are detected and reported
instead.

### Render raw package commands into agent config

Rejected. A wrapper gives devbox a stable control point for container
identity checks, diagnostics, runtime migration, and host-side failure
messages.

## Consequences

**Positive:**

- Existing user MCP configuration can be discovered and reused without being
  blindly trusted.
- Claude Code and Codex share one devbox source of truth.
- Rendered `devbox-` entries do not collide silently with inherited host MCP
  entries.
- The first implementation stays inside the existing **Container** security
  model.
- Wrapper commands give useful diagnostics and keep future runtime changes
  possible.

**Negative:**

- Users may see both inherited and `devbox-` MCP entries in their agents.
- Host-only MCP support is postponed even though some useful servers need it.
- Devbox must maintain renderers for Claude Code and Codex.
- The wrapper becomes part of the MCP startup path and must stay small,
  reliable, and well diagnosed.

## Future work

- Host MCP launcher and per-project bridge.
- `devbox mcp add` for new MCP servers that were never configured in a host
  agent. Keep this distinct from `import`: import discovers inherited
  servers, add records an explicit new devbox server.
- `devbox mcp install` materialization for existing profile entries. Keep this
  distinct from `add`: add records intent, install creates persistent runtime.
- `devbox mcp doctor` with placement explanations and firewall guidance.
- Optional repo-local MCP metadata if a team later wants shared non-secret
  recommendations.

## Updates 2026-05-27 — interactive import wizard, scope override, and devbox-project resolution

The first implementation (issues 01–10) shipped import-preserves-scope and a
minimal numeric apply picker. Hands-on use surfaced two gaps that this
amendment resolves. They are tracked as issues 11–13.

### Import keeps inherited scope by default, but offers an interactive override

The original decision was that import *preserves* the inherited scope (global
source → global profile, project source → Project profile). That stays the
**default and the only non-interactive behavior**. In an interactive TTY, the
apply wizard now additionally lets the user **override the scope per server**:
a binary toggle in both directions (project ↔ global). Non-interactive
`--apply` (explicit `--server`/`--import-id`, or no TTY) keeps the
preserve-inherited behavior unchanged — no new CI flags. Scoped secrets follow
the *chosen* scope: switching to global copies the secret value into the
global secret store, switching to project into that Project's store.

Rationale: global MCP is a deliberate user choice (ADR 0013 already refused
silent promotion). An interactive override gives that choice without breaking
the deterministic non-interactive contract.

### The wizard lives behind `--apply`, not on the dry-run preview

`devbox mcp import` without `--apply` stays a **read-only dry-run preview**
(unchanged). The interactive fzf wizard runs only on `devbox mcp import
[--all] --apply` in a TTY. This preserves the "I can run import and nothing
happens" guarantee; writes still require `--apply`.

Wizard flow: fzf multi-select over the in-scope Container-safe candidates
(falls back to the existing numeric menu when `fzf` is absent) → per selected
server a scope toggle → a project picker **whenever the resulting scope is
project** (source project pre-highlighted; for global→project there is no
default, the user picks). Servers are then applied **continue-on-error**: each
failure (missing secret value, slot conflict) is collected and reported in a
final summary, and a **single** auto-render runs over the successfully applied
servers.

### A picked devbox Project resolves to its host path via Claude's project records

Project-scoped profile entries must be keyed by the **absolute host path**,
because rendering writes into Claude Code's `~/.claude.json` `projects` map,
which is keyed by absolute path; a bare sanitized **Project** name is
insufficient (two host paths can sanitize to the same name — see ADR 0005).

There is no devbox-side registry of Project → host path. The authoritative
source is **Claude's own `projects` map**: it stores every absolute path Claude
has worked with, and because each Project is bind-mounted at its literal host
path (ADR 0004), that path is valid both on the host and inside the
**Container**. The project picker therefore offers the **intersection**:
Claude project records whose corresponding per-project devbox volume exists.
The marker volume is the canonical `devbox-<name>-history` volume (one of the
`DEVBOX_PROJECT_VOLUME_SUFFIXES` in `lib/naming.sh`, created unconditionally
for every Project), **not** `devbox-<name>-claude` — the latter is a legacy
volume that `docker-run.sh` now removes as stale (`~/.claude` is bind-mounted
directly), so gating on it would match nothing. This guarantees both a usable
host path (from Claude) and that the target is a real devbox **Project** that
can actually run the server (from the volume). A directory Claude knows but devbox has not initialized is *not*
offered — the user initializes it first and re-runs import. Basename
collisions are surfaced for explicit disambiguation, never silently guessed
(the existing `_resolve_project_key` behavior).

### `devbox mcp add` is now scheduled and shares the resolver/picker

`add` (decisions 11 and 17 in `local-plan-mcp.md`) was advertised in help/README
but never implemented by issues 01–10 — a documentation/behavior gap. It is now
scheduled as issue 13. Its interactive scope selection reuses the **same**
project picker and host-path resolver as the import wizard (global, or pick any
devbox Project with the current one pre-highlighted); `--project <name>`
resolves through the shared resolver. The `add`/`status` help text is corrected
to match reality as part of that work.
