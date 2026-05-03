# ADR 0003 — Privileged entrypoint with runuser drop, no sudo from inside the container

- **Status:** accepted
- **Date:** 2026-05-03
- **Builds on:** ADR 0002 (shared Claude config via bind mount)

## Context

ADR 0002 introduced a `HOST_HOME → /home/node` compatibility symlink so
Claude plugin registries with absolute paths rooted in the host home resolve
inside the container. The first cut placed the symlink creation in
`scripts/setup-claude.sh`, which runs as `node` from `docker exec` (CLI
flow) and from `postStartCommand` (VS Code dev container flow).

Codex review surfaced a blocker: `setup-claude.sh` called `sudo ln -sfn …`
with no NOPASSWD entry in `/etc/sudoers.d/`. In the CLI flow the script
runs without a TTY, so the `sudo` prompt cannot succeed and the entire
startup aborts before the first interactive shell attaches.

Two cheap fixes were considered and rejected:

- **NOPASSWD whitelist for init scripts.** The user explicitly does not
  want to widen `/etc/sudoers.d/`. Even narrowly scoped NOPASSWD entries
  open paths the model could exercise: rewrite a whitelisted script,
  re-trigger it, escalate. The desired property is "no privileged path
  reachable from inside the container after startup," not "specific
  privileged paths reachable to specific scripts."
- **Drop the sudo block and let the dev container path lose firewall
  init.** Acceptable for `setup-claude.sh`'s symlink, but `init-firewall.sh`
  is the security boundary itself — degrading it in any path gives the
  container unrestricted egress and breaks the default-deny model.

The third option — make the container's entrypoint privileged and have it
do all root setup before dropping to `node` — turns out to be the standard
production-container pattern and produces a smaller diff than working
around sudo. That is what this ADR records.

## Decision

The container starts as UID 0 (`docker run --user 0` from `docker-run.sh`,
`"--user", "0"` in `runArgs` for every `devcontainer.json`). The
entrypoint `scripts/devbox-entrypoint.sh` runs its **root phase** —
copy gitconfig to `/etc/gitconfig`, fix IDE-server volume ownership,
create the `HOST_HOME → /home/node` compatibility symlink, run
`init-firewall.sh` — and then `exec runuser -u node -- "$0" "$@"` to
re-enter the same script as `node`. The node phase installs the SIGTERM
handler that gracefully stops inner DinD containers and keeps PID 1
alive.

After the privilege drop:

- PID 1 is `node`. Every subsequent process inside the container inherits
  UID 1000.
- `/etc/sudoers` and `/etc/sudoers.d/` are unchanged from the previous
  layout — `node` has `sudo` but only with password. **No NOPASSWD
  entries are added.**
- All `docker exec` invocations from `docker-run.sh` pass an explicit
  `-u node` (or `-u root` in the few cases that legitimately need root,
  such as firewall reload). With `--user 0` set on `docker run`, the
  default exec user is 0, so explicit user flags are mandatory.
- `postStartCommand` in every `devcontainer.json` no longer carries a
  `sudo` call: the root setup already ran in the entrypoint, and the
  command itself only runs the user-mode steps (`start-rootless-docker`,
  `setup-chezmoi`, `setup-claude`).

`runuser` is part of util-linux and ships with the Debian-based
`node:22` image — no additional package install is required. It does
not authenticate (root → unprivileged user is always free) and does
not create a PAM login session by default, so the privilege drop is
deterministic and side-effect free.

## Consequences

**Positive:**

- **Single privileged code path.** All container privileged operations
  live in `scripts/devbox-entrypoint.sh`. Reviewing the security surface
  is reading one ~30-line script.
- **Identical behaviour across entry points.** `devbox` from CLI,
  `devbox code <name>`, `docker start` on a stopped container, and VS
  Code/Cursor "Reopen in Container" all execute the same entrypoint at
  start, so all paths get firewall init, the host-home symlink, and the
  gitconfig copy. There is no longer a degraded path.
- **No NOPASSWD surface.** The model running inside the container has
  exactly the privileges it had before: `node`-level access, with `sudo`
  gated by a password it does not have. There is no whitelisted script
  it can rewrite and re-trigger. The "root" credentials at container
  start come from the Docker daemon on the host, not from anything
  reachable from inside.
- **Smaller `docker-run.sh`.** Two `docker exec -u root` blocks
  (firewall init in fresh-start and `restart_exited_container`) are
  redundant once the entrypoint owns root setup, and were removed.
- **No password prompt in any flow.** `--user 0` is a Docker daemon
  flag, not a sudo escalation. The host user is already in the
  `docker` group; adding `--user 0` does not change the UX.

**Negative:**

- `docker exec` without `-u node` would now default to UID 0 because
  `docker run --user 0` was used. Every existing exec call had to be
  audited and given an explicit user; future contributors must remember
  to do the same. Mitigated by documentation here and in the comment
  next to `--user 0` in `docker-run.sh`.
- The entrypoint becomes a real script with branching (root phase vs.
  node phase) instead of a five-line keep-alive loop. Slight increase
  in surface area, but the alternative was per-script `sudo` blocks
  duplicated across `setup-claude.sh`, IDE flows, etc.
- `runuser`'s default behaviour preserves environment variables (HOST_HOME,
  PATH, etc.), which is what we want. If a future Debian release
  changes that default or PAM policy, the privilege drop could
  silently strip env. Mitigation: smoke test on image rebuild
  verifies `$HOST_HOME` is visible after the drop.

## Alternatives considered

- **Narrow NOPASSWD sudoers entries** for `init-firewall.sh` and a small
  symlink wrapper — rejected on the user's explicit security stance
  (no widening of the sudo surface, even narrowly).
- **Delete the `devcontainer.json` files** so VS Code "Reopen in
  Container" stops being a supported path. Acceptable but a UX loss
  (Zed and other future editors that consume `devcontainer.json`
  would not work). The privileged-entrypoint refactor preserves these
  paths at lower cost than expected.
- **Run `init-firewall.sh` from `initializeCommand`** (host-side hook
  that fires before container start). Rejected: that hook runs
  pre-container and cannot `docker exec` into a container that does
  not exist yet.

## References

- `scripts/devbox-entrypoint.sh` — the entrypoint with root and node phases.
- `docker-run.sh` — `--user 0` on `docker run`, explicit `-u node` on
  `docker exec`, two redundant `-u root` exec blocks removed.
- `.devcontainer/devcontainer.json`, `.devcontainer/cursor/devcontainer.json`,
  `devcontainer-standalone.json` — `runArgs` adds `--user 0`,
  `postStartCommand` no longer carries `sudo`.
- `runuser(1)` — util-linux manual; "executes a command with substitute
  user and group ID". When invoked as root, never prompts.
- ADR 0002 — the bind-mount layout this entrypoint cooperates with.
