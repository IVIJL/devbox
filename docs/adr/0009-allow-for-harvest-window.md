# ADR 0009 — Time-bounded `allow-for` window via DNS-driven harvest pool

- **Status:** accepted
- **Date:** 2026-05-15

## Context

Devbox's default-deny firewall (ADR 0001) is correct for steady-state work
but painful during exploratory tasks where the set of needed domains is
unknown — typically an LLM agent doing nonsupervised research, or an
unfamiliar `npm install` pulling exotic dependencies. The reactive
workflow today is "run task → it fails → `devbox blocked` → allow → retry",
which is fine for a developer-in-the-loop but unworkable for an autonomous
agent.

The user wants a **proactive** workflow: start a time-bounded session in
which the firewall passively allows non-allowlist destinations *and
records them*, so the session produces a harvest log that informs the
durable allowlist afterward. The trust requirement is asymmetric: the
session is a security exception, so the *control state* (timer, sentinel,
firewall rules) must be tamper-proof against code running inside the
container, but the *output state* (the harvest log itself) is informational.

## Decision

A new `devbox allow-for [minutes] [project]` command opens an
**Allow-for window** in one container. During the window:

1. **Catch-all ipset.** A second Netfilter set (`harvest-pool`) is populated
   by dnsmasq's `ipset=//harvest-pool` directive (the empty-domain form
   matches every A/AAAA query). iptables gains one `ACCEPT --match-set
   harvest-pool dst` rule *before* the final `REJECT`. The original
   `allowed-domains` ipset and the `REJECT` baseline remain unchanged.
2. **DNS pinning** (made permanent, not window-scoped). Outbound DNS is
   restricted to `127.0.0.1` on UDP/TCP 53; DoT on TCP 853 is
   `REJECT`ed. This guarantees every name resolution flows through the
   audited resolver, which is the precondition that makes the harvest pool
   complete.
3. **Sentinel state** in `/etc/devbox-shared/.allow-for.state` (root-owned
   inside the container, mode 0644). Holds `started_at`, `expires_at`,
   container name, and the teardown daemon's PID. The node user can read
   it but cannot modify it.
4. **Tamper-proof harvest log** at
   `/var/log/devbox/allow-for/<container>-<ISO>.log` on the host. The
   directory is created at install time as `root:root 0755`, mounted into
   the container without `:ro`. Files are written by the in-container
   root daemon with mode 0644. The node user (= host user UID 1000)
   can read but cannot delete or overwrite.
5. **Reset-clock semantics.** A second `devbox allow-for N` during an
   active window overwrites the `expires_at` to "now + N min". The harvest
   log accumulates within the session.
6. **Closeout on container restart.** `init-firewall.sh` checks the
   sentinel; if it finds a window state that did not complete cleanly, it
   writes the final harvest log with a "window interrupted by restart"
   marker and emits the notification.
7. **Clickable Windows toast** via inline COM PowerShell (no module
   install) registered under AppId `Devbox.AllowFor` (one-time HKCU
   registry write at install). Click opens File Explorer at the harvest
   log via WSL UNC path. Fallback cascade: `notify-send` on native Linux
   with `$DISPLAY`, else silent (the log file is always written).

## Considered options

**Default-accept during the window.** Simply replace the final `REJECT`
with `ACCEPT` for the window's duration. Trivial to implement, no second
ipset. Rejected because it lets hardcoded-IP traffic out without ever
touching the resolver, which both expands the threat surface and breaks
the auditing invariant ("every successful outbound passed through our
DNS"). Net cost of the harvest-pool approach is ~5 lines of extra code
for a meaningful gain.

**Auto-add on DNS query.** Tail the dnsmasq query log, add new domains to
the allowlist on the fly. Rejected because dnsmasq writes the query log
*after* responding, so a tail-watcher always lags ~30 ms behind — the
client's `connect()` to a freshly-resolved IP races the ipset update and
typically loses (client gets `ICMP admin-prohibited`, fails without
retry). The first request to each new domain would fail intermittently
with no obvious cause.

**MITM proxy for full URL audit.** Run Squid or mitmproxy in the
container to capture HTTP paths, not just hostnames. Rejected as out of
scope: a separate project, materially different threat model, and not
needed for the "which domains do I need to add to the allowlist" use
case.

**Background daemon on the host instead of inside the container.**
Survives container restart but complicates the privilege story (the host
daemon would `docker exec` into the container) and provides no benefit
for the chosen "restart = end window" semantics.

## Consequences

**Positive:**

- LLM agents and other unsupervised automation can complete tasks that
  hit unknown domains without the user mediating each allow.
- Hardcoded-IP traffic remains blocked during the window. The auditing
  invariant holds: every successful outbound proves a DNS query through
  the in-container resolver.
- The harvest log is fully tamper-proof against code running as the
  `node` user inside the container — the only privilege boundary that
  matters in practice. The push notification carries the summary out of
  the container the moment the window ends, so even a log overwrite race
  (which the perms prevent anyway) would not hide information from the
  user.
- DNS pinning closes the broader hole where containers could resolve via
  `8.8.8.8`/`1.1.1.1` and bypass the in-container query log entirely.
  This is a security win independent of the `allow-for` feature.

**Negative:**

- One-time `sudo` prompt at install for the `/var/log/devbox/allow-for/`
  root-owned directory. Devbox already requires sudo for DNS install, so
  this is consistent rather than novel.
- The pending-notification hand-off (Phase 3) requires a host-user-owned
  subdirectory `/var/log/devbox/allow-for/pending/` so the host-side
  deliver script can rename-claim files atomically. The parent log dir
  stays `root:root 0755` (harvest logs unchanged). Inside the container
  the host UID maps to the `node` user, so the in-container adversary
  shares write access to that subdir and can forge or replace pending
  files. Two complementary defences close every vector this opens:
  - **Symlink-clobber resistance on the writer side.** The in-container
    teardown daemon never writes directly into the user-writable
    `pending/`. It `mktemp`s in a sibling `.tmp/` subdir (mode 0700
    root:root, under the root-owned `allow-for/` parent so the node
    user can neither enumerate it nor relocate it), writes the JSON,
    and atomic-renames into `pending/`. `rename(2)` replaces a
    symlink at the destination instead of following it, so a
    pre-planted `.pending-… → /etc/shadow` symlink is harmlessly
    overwritten. The TOCTOU race a user-writable tempdir would allow
    is eliminated by writing in the root-only dir.
  - **Filesystem-trust validation on the reader side.** The host
    deliver script treats pending JSON contents as untrusted: it
    derives the harvest log path by reconstructing it from the pending
    filename (which must match the writer's strict
    `<container>-<ts_safe>` shape) and verifies the corresponding log
    file exists in the root-owned parent dir. A forged pending
    pointing at `/etc/passwd` or `evil.bat` cannot reach the toast's
    `launch="file://..."` URI because the reconstructed path is fixed
    and the existence check fails for any log the in-container root
    daemon did not actually write. The attacker-controllable display
    fields (`reason`, `domain_count`, `top_domains`) are bounded and
    only affect the toast's text body — at worst a misleading
    message, no RCE.
- `init-firewall.sh` gains a new responsibility (sentinel closeout) and a
  small amount of state-aware code. The "fresh-deny from scratch" model
  weakens slightly.
- Per-window dnsmasq restart cost (~500 ms) on window open and close.
  Tolerable given the typical 15-min duration.
- DoH (DNS-over-HTTPS) on port 443 to **unknown** hostnames cannot be
  detected without deep packet inspection. The catch-all ipset still
  blocks the resulting connect to the target IP, so DoH does not become a
  general bypass — it only enables data exfiltration *to* the chosen DoH
  endpoint, which the harvest log records. Acceptable for the threat
  model.

## Future work

Items deliberately deferred from the MVP, to be picked up after the
feature has run in real use:

- `devbox allow-for --review [project]` — fzf picker over the most recent
  harvest log, promoting selected entries into the durable allowlist.
- `devbox allow-for --history [project]` — listing of past runs (today
  this is `ls /var/log/devbox/allow-for/`, but a curated view is more
  user-friendly).
- Heuristic grouping in the report (e.g. collapse five `*.cloudfront.net`
  edges to one line). Requires shape data from real harvest logs to
  design well.
- Built-in DoH endpoint blacklist (`dns.google`, `cloudflare-dns.com`,
  `dns.quad9.net`, `mozilla.cloudflare-dns.com`, `doh.opendns.com`) baked
  into the dnsmasq config to refuse resolution of known public DoH
  providers entirely. A small standalone security upgrade, not tied to
  `allow-for`.
- Optional Pi-hole-style malware blacklist consulted *before* a domain
  enters the harvest pool. A larger project; depends on a maintained
  upstream list.
- Status-line integration (Powerlevel10k / starship segment) showing the
  active window and time remaining.

## References

- `init-firewall.sh` — gains the DNS-pinning rules and the
  sentinel-closeout logic.
- `lib/allowlist.sh` — unchanged; harvest pool is a separate concern.
- `scripts/start-allow-for-window` (new) — root-privileged window setup.
- `scripts/teardown-allow-for-window` (new) — root-privileged window
  teardown + harvest log write + notification.
- `docker-run.sh` — new `MODE=allow-for` subcommand.
- ADR 0001 — the underlying dnsmasq/ipset model this feature extends.
- ADR 0003 — the root/node privilege boundary this feature relies on.
