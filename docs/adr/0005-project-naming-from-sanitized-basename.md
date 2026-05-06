# ADR 0005 — Project naming from sanitized basename

- **Status:** accepted
- **Date:** 2026-05-04
- **Builds on:** ADR 0004 (workspace mount no longer derives from project name)

## Context

Devbox derives several names from the project's path basename:

| Derived thing            | Format                                |
|--------------------------|---------------------------------------|
| Container name           | `devbox-<project>`                    |
| Hostname (`--hostname`)  | `<project>`                           |
| Per-project volumes      | `devbox-<project>-{history,docker}`   |
| Workspace alias symlink  | `/workspace/<project>`                |
| Traefik route host       | `[<port>.]<project>.<route-domain>`   |

The same conceptual `<project>` was previously computed inline at ~25 call
sites across `docker-run.sh`. Forward construction used the **raw basename**
(e.g. `Foo Bar` → `--hostname "Foo Bar"`, `-v devbox-Foo Bar-history:…`),
while reverse derivation (`${container#devbox-}`, the regex
`^devbox-.+-(history|docker)$`) implicitly assumed a **sanitized** form.

For an ASCII basename without spaces this matched by coincidence. For a
project at `~/Code/Foo Bar`:

- `docker run --hostname "Foo Bar"` → docker rejects, container fails to start.
- `-v devbox-Foo Bar-history:…` → docker mis-splits on the embedded space,
  produces a malformed mount, and `devbox reset/remove` later cannot find the
  resulting volume because its reverse-pattern expects the sanitized form
  (`Foo-Bar`).

This was a latent lifecycle bug — silent until a user happened to put a
project under a path with whitespace or diacritics. There was no module that
"owned" the project-naming concept; format changes (different prefix, a new
volume suffix, a different traefik domain) required coordinated edits in
three or more files.

## Decision

Introduce `lib/naming.sh` as the single source of truth for project naming.

**Sanitize end-to-end.** Hostname, volume names, and Traefik route host are
all built from the sanitized project name, matching the reverse-derivation
patterns. Forward and reverse become symmetric by construction.

**Public API:**

- `devbox::sanitize <s>` — `tr -cs 'a-zA-Z0-9_.-' '-'` followed by
  trim of leading/trailing dashes. Idempotent.
- `devbox::names_from_path <path>` — sanitizes the basename of a host
  filesystem path; exports the full set of `DEVBOX_*` derived names.
- `devbox::names_from_token <token>` — sanitizes a user-supplied token (e.g.
  `devbox foo bar`). Idempotent: the token form yields the same result as
  the path form for the same project.
- `devbox::volume_name <project> <suffix>` — builds `devbox-<p>-<s>`.
- `devbox::route_host <project> [port]` — builds the Traefik host with an
  optional port prefix.
- `devbox::project_volume_regex` — derived from
  `DEVBOX_PROJECT_VOLUME_SUFFIXES` so adding a suffix updates every reverse
  match site.

**Exported globals after `names_from_*`:** `DEVBOX_PROJECT_NAME`,
`DEVBOX_PROJECT_NAME_RAW`, `DEVBOX_CONTAINER_NAME`, `DEVBOX_HOSTNAME`,
`DEVBOX_VOL_HISTORY`, `DEVBOX_VOL_DOCKER`, `DEVBOX_WORKSPACE_ALIAS`. The
`DEVBOX_*` prefix avoids collision with bash's read-only `HOSTNAME`.

`DEVBOX_PROJECT_NAME_RAW` is exported (in addition to the sanitized name)
specifically to support the orphan-volume warning below.

**Out of scope:**

- The workspace **mount** (`-v $PROJECT_PATH:$PROJECT_PATH`) is a literal
  host path and is not derived from the project name (see ADR 0004).
  `WORKSPACE_DIR` is intentionally not part of this module.
- Container-side `setup-claude.sh` keeps its own one-line derivation
  (`/workspace/$DEVBOX_PROJECT_NAME`) from the env var. Sourcing
  `lib/naming.sh` inside the container would not pay back the cost.
- `apply_port_routes` as a whole stays in `docker-run.sh`; only the URL
  format goes through `devbox::route_host`. Traefik orchestration is a
  separate deepening candidate (`lib/traefik.sh`).

## Orphan volumes

The behavior change above is a **fix**, but on existing hosts there may be
volumes whose names use the old un-sanitized form (e.g.
`devbox-Foo Bar-history`). After sanitize-end-to-end, devbox no longer
references those volumes — and `devbox remove` cannot find them because
its reverse-derivation regex assumes the sanitized shape.

`docker-run.sh` therefore prints a one-line warning when
`DEVBOX_PROJECT_NAME_RAW != DEVBOX_PROJECT_NAME` **and** a legacy volume
exists, telling the user the exact `docker volume rm` command to run.

We deliberately do **not**:

- gate container start on the warning (the warning is informational),
- attempt automatic rename or copy (volumes can be large and the failure
  modes are unpleasant), or
- attempt to migrate data — the user owns this decision.

## Consequences

- Format changes to any derived name (different prefix, additional volume
  suffix, different route domain) edit one file.
- Whitespace/diacritics in project basenames now produce a working
  container and a discoverable volume set, rather than a docker rejection
  or a silent reverse-derivation miss.
- `tests/naming.sh` provides plain-bash coverage of the module without a
  test harness — adding a bats harness is intentionally deferred.
- Users with legacy un-sanitized volumes see a one-time warning; the data
  is not deleted automatically.

## Updates 2026-05-06 — tighten allowlist to RFC 1034/1035 LDH

The original sanitize accepted `[A-Za-z0-9_.-]`. Both `_` and `.` are valid
in docker container/volume names but **not** in DNS labels (RFC 1034/1035).
The same project name flows into the Traefik route host
`[<port>.]<project>.127.0.0.1.traefik.me`, where Django and other
RFC-strict frameworks reject hosts containing `_` with `DisallowedHost`.
A project at `~/Projekty/universe_media_api` produced exactly this:
the container started, but every browser hit died at the WSGI/ASGI host
check.

Tighten the allowlist to strict LDH (`[a-zA-Z0-9-]`). Same algorithm,
narrower set. `tr -s` collapse and edge-trim are unchanged; idempotency
holds.

**Active migration, not warn-only.** The original ADR took a deliberate
warn-only stance for un-sanitized volumes — "volumes can be large and the
failure modes are unpleasant." That policy assumed a user-driven cause
(rename the project directory, change basename). The LDH tightening is
different: it's a **break-fix** where every existing project with `_` or
`.` in its basename has been silently broken under Traefik routing.
Leaving those projects warn-only would force every user to manually
rename containers + copy volumes by hand.

`scripts/migrate-naming-ldh.sh` therefore actively migrates:

- per-project volumes are data-copied (`alpine cp -a`) into
  freshly-created LDH-named volumes, then the legacy volumes are
  removed. The migration **refuses** to migrate a volume whose LDH
  target already exists: two distinct legacy basenames can sanitize to
  the same LDH name (e.g. `foo_bar` and `foo.bar` both → `foo-bar`),
  and silent merge under `--auto` would mix unrelated projects' data.
  The user resolves manually with `docker volume rm <stale>` and
  `devbox migrate-naming`.
- the legacy container is stopped and removed (its `--hostname` is
  immutable post-`docker run`, so a rename would leave the un-LDH
  hostname inside; the next `devbox <project>` recreates the container
  cleanly against the migrated volumes)
- stale Traefik dynamic configs keyed by the legacy container name are
  deleted; `apply_port_routes()` regenerates them on the next start

`devbox update` runs the migration with `--auto`, mirroring the
`migrate-to-bindmount.sh` hook pattern (ADR 0002). For users who don't
run `devbox update`, `docker-run.sh` still emits a runtime warning when
`DEVBOX_PROJECT_NAME_RAW != DEVBOX_PROJECT_NAME` and a legacy
container/volume is found, pointing at `devbox migrate-naming`.
