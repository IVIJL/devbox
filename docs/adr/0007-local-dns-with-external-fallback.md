# ADR 0007 — Local DNS resolver for `.test` URLs with external fallback

- **Status:** accepted (design only, implementation pending)
- **Date:** 2026-05-11
- **Builds on:** ADR 0001 (dnsmasq already in image), ADR 0005 (`devbox::route_host`
  is the single source of truth for the URL format)

## Context

Devbox routes per-project HTTP traffic through a shared Traefik proxy. The
URL format produced by `devbox::route_host` was
`<port>.<project>.127.0.0.1.traefik.me`. `traefik.me` is an external wildcard
DNS service (`*.traefik.me` → `127.0.0.1`) operated by a third party.

In May 2026 the service stopped resolving — the domain appears to be down or
sold. Every existing devbox URL silently broke at the DNS layer. There is no
recourse: we do not control the domain.

The same risk applies to obvious alternatives in the same category — `nip.io`,
`sslip.io`, `xip.io` (already dead) — anything that maps a wildcard subdomain
to a loopback or arbitrary IP through a publicly-resolvable DNS service.
Single point of failure that we cannot fix.

### Client surface that must work

Three OSes need to resolve the dev URLs from the **host**:

- **Browser on the host** (Chrome / Firefox / Edge / Safari on Windows /
  macOS / Linux) — primary dev workflow.
- **CLI on the host** (`curl`, `wget`, `httpie`, `Invoke-WebRequest`) — API
  tests, healthchecks, smoke scripts.

Not in scope:

- Container-to-container — already solved by Docker network names
  (`devbox-<project>`) per commit c754e39.
- LAN mobile / external device — interesting but architecturally bigger
  (needs LAN IP responses from dnsmasq, router DNS push or per-device DNS
  config, firewall openings). Deferred.

### Resolver reality per OS

The `*.localhost` TLD is special: modern browsers map `*.localhost` →
loopback **as a baked-in browser rule**, bypassing the system resolver
entirely. That gives a tempting zero-setup browser path, but it splits
behavior:

- Browser path uses the baked-in rule and never sees our DNS.
- CLI path uses the system resolver and **does not** resolve `*.localhost`
  by default on any of the three OSes (glibc, mDNSResponder, Windows DNS
  Client all return NXDOMAIN for arbitrary subdomains).

We would end up with two failure modes (browser works, CLI doesn't, or the
inverse if our DNS dies) and confusing debugging.

`.test` is RFC 2606 reserved-for-testing. Browsers have no baked-in fast
path for it but treat it as a "private/local" TLD that **bypasses DoH** and
falls back to the system resolver — the same path the CLI takes. One
architecture, one failure mode, one mental model.

### What the system can and cannot do

Each of the three OSes has a built-in per-TLD DNS routing feature, which we
can configure without third-party software:

- **macOS** — `/etc/resolver/<TLD>` file in the Apple Resolver framework.
  Single-line text file. No daemon restart.
- **Linux + systemd-resolved** — drop-in in
  `/etc/systemd/resolved.conf.d/`, `Domains=~test` syntax routes only the
  matched TLD.
- **Linux + NetworkManager-dnsmasq** — drop-in in
  `/etc/NetworkManager/dnsmasq.d/`, `server=/test/127.0.0.1` syntax.
- **Windows 8+** — NRPT (Name Resolution Policy Table) via PowerShell
  `Add-DnsClientNrptRule`. Persistent across reboots in the registry.

Per-TLD routing has higher precedence than interface-default DNS in all
three implementations, so VPN / Tailscale / Pi-hole continue to work for
every other domain.

There are real edge cases where this still fails — Tailscale Magic DNS with
`accept-dns=true` rewrites `/etc/resolv.conf` and ignores systemd-resolved
drop-ins; corporate VPNs that force-route all DNS through the tunnel
bypass NRPT — but they are minority cases and we degrade visibly when
post-install verification fails.

## Decision

Stand up a **self-hosted dnsmasq container** as part of the devbox shared
infrastructure (alongside `devbox_traefik`), with a **fallback to an
external wildcard DNS provider** (`sslip.io`) when the local path is not
possible. Both URL forms coexist in Traefik routing rules so a mode switch
never requires regenerating routes.

### Component layout

```
HOST OS per-TLD DNS routing  ──►  devbox_dns (dnsmasq :53/127.0.0.1)
                                       │
                                       ▼ resolves *.test → 127.0.0.1
HTTP client (browser / CLI)  ──►  devbox_traefik :80
                                       │
                                       ▼ Host header match
                                  devbox-<project>
```

### Shared-infra naming: underscore separator

Shared infrastructure containers use an **underscore** separator
(`devbox_traefik`, `devbox_dns`); user project containers use a
**dash** separator (`devbox-<project>`).

`devbox::sanitize` collapses every non-LDH character — including
underscore — to a dash. The function cannot produce a token containing
`_`. Therefore no user project, however its source folder is spelled,
can ever sanitize to a name that collides with shared infra. The two
namespaces are provably disjoint at the naming layer.

This replaces an earlier convention where the resolver was named
`devbox-dns`. A user folder named `dns/` sanitized to `devbox-dns`,
identical to the shared resolver — `devbox` in that folder would
attach to dnsmasq, and enumeration would permanently hide that user
project. The legacy dash-separator names are migrated by
`scripts/migrate-shared-infra-naming.sh`, auto-triggered on
`devbox update`.

### TLD: `.test` (not `.localhost`)

`.test` is RFC 2606 reserved-for-testing. Browser **and** CLI both go
through our DNS path — single mental model, single failure mode. We
deliberately give up the browser zero-setup fast-path that `*.localhost`
would provide. The downside (browser breaks too when DNS misconfigures)
is worth the consistency.

LAN mobile (deferred) is only feasible with `.test`, never with
`*.localhost` — on a phone the baked-in rule would map to the phone's own
loopback, not to the dev host. Choosing `.test` keeps that door open.

### Dual-mode operation with sticky preference

Three modes, persisted in `~/.config/devbox/dns.conf`:

| Mode       | URL                                          | When chosen                                          |
|------------|----------------------------------------------|------------------------------------------------------|
| `local`    | `<port>.<project>.test`                      | Default. Requires `127.0.0.1:53` free + admin elevation. |
| `external` | `<port>.<project>.127.0.0.1.sslip.io`        | Fallback when local is unavailable, or user override.    |
| `auto`     | resolves to one of the above                 | User-facing preference. Re-detects on `devbox dns-install`. |

`dns.conf` schema (shell-style, sourceable):

```sh
preferred=auto                    # user choice: auto | local | external
active_domain=test                # resolved by install/detection
external_provider=sslip.io        # configurable so we are not locked to one
```

`preferred` is what the user wants. `active_domain` is what is reasonably
running. They are separate so the user can keep `preferred=local` even
while temporarily on `active_domain=127.0.0.1.sslip.io` (e.g. port 53
borrowed by a one-off Pi-hole test); next `dns-install` retries.

### Both URLs work simultaneously in Traefik

Every generated Traefik dynamic route emits a **dual `Host()` rule**:

```yaml
rule: "Host(`8000.frontend.test`) || Host(`8000.frontend.127.0.0.1.sslip.io`)"
```

Consequences:

- Mode switches (`devbox dns-install --external`) do **not** require
  regenerating dynamic config files. They only change which URL form
  `devbox port` / `devbox ports` displays.
- A colleague on a video call can paste the sslip.io form and have it
  work for them without our resolver configured.
- If the local dnsmasq dies (container crash, port 53 stolen by a Pi-hole
  install), the sslip.io URL still works as a manual fallback — the user
  can copy-paste the alternate hostname from `devbox dns-status` and keep
  going. dnsmasq downtime degrades the *default* URL but not connectivity
  to running services.

The cost is one extra hostname per route in `~/.config/devbox/traefik/dynamic/*.yml`.
Traefik handles `||` natively; no rule explosion.

### External provider: `sslip.io` (configurable)

Chosen over `nip.io` because:

- Active maintenance (recent commits, responsive issue tracker).
- Open-source and **self-hostable** — if it ever dies the way traefik.me
  did, we can spin our own.
- Same URL shape (`<ip>.sslip.io`), so the migration cost is just a
  string change in `lib/naming.sh`.

`external_provider=` is configurable in `dns.conf` so the user (or a future
default) can swap to `nip.io` or a self-hosted instance without rebuilding
the image. We deliberately do **not** hard-code a fallback chain — the
config field is editable.

### dnsmasq container

Image: **the existing `vlcak/devbox:latest`**. ADR 0001 already installs
`dnsmasq` for the firewall path, so no new image, no supply-chain surface.
The container runs `dnsmasq --keep-in-foreground` with a single config file
bind-mounted read-only.

Port binding: `127.0.0.1:53:53/{udp,tcp}` (host loopback only, not
`0.0.0.0`). Future LAN mode would re-bind to `0.0.0.0` opt-in.

dnsmasq config (`config/dns/devbox.conf`, copied to
`~/.config/devbox/dns/devbox.conf` on install):

```conf
no-resolv          # do not read /etc/resolv.conf — no upstream
no-poll            # do not reload on resolv.conf change
local-service     # respond only to networks declared as local
local=/test/       # authoritative for .test
address=/test/127.0.0.1
```

`no-resolv` makes the container an **authoritative-only** resolver for
`.test`. Any non-`.test` query returns REFUSED. The container is not an
open resolver; a misconfigured host resolver leaking `google.com` to us
will fail visibly rather than silently exfiltrate via 8.8.8.8.

### Lifecycle: shared with `devbox_traefik`

`devbox_dns` starts when the first devbox project starts, stops when the
last one stops. Symmetric to `bootstrap_traefik` / `stop_traefik_if_idle`.

Rejected alternative: always-on dnsmasq. When no devbox is running, Traefik
is down and any `.test` URL would hit "Connection refused" on port 80
anyway. Keeping DNS alive in isolation has no functional value and an
operational cost (one more service to babysit at host boot).

### Per-OS one-time setup via `devbox dns-install`

The host-side per-TLD routing setup is delegated to a single
`devbox dns-install` command. It detects platform, performs the right
setup, verifies, and writes `dns.conf`. Re-runs are idempotent.

Auto-triggered by:

- `install.sh` (first-time install).
- `devbox update` when `dns.conf` is missing or contains legacy
  `traefik.me`.
- `bootstrap_dns()` self-heal when configs go missing on disk.

On WSL2 the setup is **two-sided**: the WSL2 distro needs systemd-resolved
drop-in for WSL2-side `curl`, and the Windows host needs an NRPT rule for
the browser + native Windows tools. WSL2 localhost forwarding means both
clients ultimately hit the same dnsmasq listener at `127.0.0.1:53` inside
WSL2. `dns-install` invokes Windows-side via `powershell.exe Start-Process
-Verb RunAs` to trigger UAC; if the user declines, we fall through to
`external` mode.

### Active migration, not warn-only

`traefik.me` is dead. Every existing dynamic config file under
`~/.config/devbox/traefik/dynamic/` hard-codes a hostname rule that no
longer resolves. Leaving users on warn-only would force them to manually
regenerate routes one by one.

Following the pattern set by ADR 0005's LDH migration, `devbox update`:

1. Detects `traefik.me` references in dynamic configs.
2. Runs `devbox dns-install` if `dns.conf` is missing.
3. Regenerates all dynamic config files with dual-host rules.
4. Prints a visible WARN banner explaining the migration and the new URL
   format.

Memory feedback "active migration for break-fix" (vs ADR 0005's warn-only
stance for user-driven renames) applies here.

### Self-healing

`bootstrap_dns()` runs two `ensure_*` functions before starting the
container:

- `ensure_dns_runtime_config()` — if `~/.config/devbox/dns/devbox.conf` is
  missing but `devbox_dns` is running (or about to start), regenerate from
  the baked-in template at `config/dns/devbox.conf` and SIGHUP the running
  container.
- `ensure_dns_meta_config()` — if `~/.config/devbox/dns.conf` is missing
  but the container is running, write a sane meta-config inferred from
  the running state (`active_domain=test`). If both are missing and no
  container, defer to `devbox dns-install`.

Memory feedback "no silent failures" applies: each repair surfaces a
yellow WARN line collected via the `WARNINGS=()` pattern.

### Pre-flight collision detection

`bootstrap_traefik()` and `bootstrap_dns()` both check their ports before
attempting `docker run`. Pre-flight failures fail-loud with the conflicting
process listed (`ss -lntp`), pointing the user at the next step:

- Port 53 (dnsmasq) — fallback to `external` mode automatically.
- Port 80 (Traefik) — no fallback exists; report the conflict and exit.
  Without Traefik, `.test` URLs would dead-end at 127.0.0.1:80 anyway.

## Refactor of `lib/naming.sh`

The constant `DEVBOX_ROUTE_DOMAIN="127.0.0.1.traefik.me"` is replaced by a
lazy-loaded function `devbox::route_domain()` that reads `dns.conf` and
defaults to `test` if absent. The public surface adds:

- `devbox::route_domain` — returns the active domain string for display.
- `devbox::route_hosts <project> [port]` — yields **all** hostnames
  (local + external), one per line, for dual-host rule generation.
- `devbox::route_host_display <project> [port]` — yields the **single**
  user-facing hostname per the active mode (used by `devbox port`,
  `devbox ports`).

The existing `devbox::route_host()` signature changes meaning — old
callers must update. There are no out-of-tree consumers; the surface is
internal.

## Out of scope (deliberately deferred)

- **LAN mobile access** — would require dnsmasq on `0.0.0.0:53` returning
  the host's LAN IP instead of 127.0.0.1, host firewall openings, and
  per-device DNS configuration on the phone. Architecturally feasible but
  out of MVP scope.
- **HTTPS for `.test` URLs** — Traefik can mint certs via Let's Encrypt
  for sslip.io (real cert) but not for `.test` (not a real TLD). Would
  need a local CA and `mkcert`-style trust install. Not required by
  current workflow; defer until a service forces it.
- **Tailscale Magic DNS auto-coexistence** — Tailscale's `accept-dns`
  mode rewrites `resolv.conf` and breaks systemd-resolved per-TLD
  routing. Detect at post-install verify and fall back to `external` with
  a documented troubleshooting note.
- **Self-hosted sslip.io** — `external_provider=` is configurable; if
  sslip.io ever fails the way traefik.me did, the user can point it at a
  self-hosted instance without code changes.

## Consequences

**Positive:**

- Fully offline operation in `local` mode — no third-party DNS dependency
  for the default path.
- Cross-platform (Win / Mac / Linux / WSL2) via vendor-built-in features;
  no Acrylic DNS Proxy, no BIND, no system-wide DNS replacement.
- Scoped resolver: per-TLD routing means VPN / Pi-hole / corporate DNS
  for every other domain continues to work untouched.
- URL coexistence via dual `Host()` rules removes the regeneration step
  on mode switch and gives a permanent secondary path when the primary
  resolver has trouble.
- Lessons applied from traefik.me: `external_provider` is configurable,
  so we are never one Twitter announcement away from being stuck again.

**Negative:**

- First-time setup requires sudo / admin elevation on every OS. The
  installer handles it, but the elevation prompt is unavoidable.
- WSL2 needs two-sided setup (WSL2-internal systemd-resolved +
  Windows-host NRPT). Detection + dispatch is inside `dns-install`, but
  if Windows UAC is declined we silently degrade to `external` mode and
  must surface that clearly.
- dnsmasq container occupies host `127.0.0.1:53`. Conflicts with a host
  Pi-hole or BIND install. Pre-flight detects this and falls back to
  `external`.
- Per-route dynamic config doubles in line count (two hostnames per
  router). Manageable; Traefik handles `||` rules natively.
- Browser depends on our DNS for `.test` (no zero-setup fallback like
  `*.localhost` would have given). Acceptable trade-off for the
  browser ↔ CLI parity.

## References

- `local-plan-local-dns-test.md` — implementation plan with phase
  breakdown.
- `lib/naming.sh:22` — current `DEVBOX_ROUTE_DOMAIN` constant; target of
  refactor.
- `docker-run.sh:127` — `bootstrap_traefik`, the pattern that
  `bootstrap_dns` will mirror.
- `init-firewall.sh` + `lib/allowlist.sh` — existing dnsmasq usage in the
  firewall path (ADR 0001).
- `scripts/migrate-naming-ldh.sh` — pattern for active migration hooked
  into `devbox update` (ADR 0005).
- RFC 2606 — reserved TLDs including `.test`.
- RFC 6761 — special-use TLDs (`.localhost`, etc.) and the reasons we
  do **not** use them here.
