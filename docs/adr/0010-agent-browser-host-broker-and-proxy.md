# ADR 0010 — Agent-browser via host broker and forward proxy

- **Status:** proposed
- **Date:** 2026-05-19

## Context

LLM agents working inside a devbox container increasingly need a real
browser — for taking screenshots of the project's dev URLs, reading
JS console errors and network failures, navigating documentation, and
testing UI changes against the running stack. We picked
[vercel-labs/agent-browser](https://github.com/vercel-labs/agent-browser)
as the CLI surface because it speaks CDP, has built-in policy hooks
(`--allowed-domains`, `--action-policy`, `--confirm-actions`,
`--allow-file-access` opt-in), and supports `--cdp <url>` to drive a
remote Chrome.

The hard question is **where Chrome runs** and **how the container
reaches it without breaking the devbox security model**:

- Chrome must be visible on the user's desktop (visual audit; the user
  watches what the agent does).
- Chrome must not be the user's personal Chrome (CDP has no auth and
  exposes cookies, history, extensions, downloads, native messaging —
  trivial compromise of all logged-in sessions).
- The container's default-deny firewall (ADR 0001) must not be silently
  bypassed: the agent must not gain unconstrained internet just because
  a browser was added.
- The design must work on Linux native, WSL2, and macOS without two
  parallel implementations.

CDP is "remote control over the browser process", not "a debug port".
Chrome 136+ enforces a non-default `--user-data-dir` for remote
debugging precisely because earlier versions were routinely exploited
to dump cookies. The threat model has to start from "anyone who reaches
CDP owns the Chrome process and the OS identity it runs as".

## Decision

Three new host-side actors, controlled by `devbox agent-browser ...`
commands, behind a two-layer time gate.

### Actor 1: Host agent Chrome

Launched by the host-side broker (`devbox agent-browser start`) under
a dedicated OS user `devbox-agent` (created idempotently at install).
The OS-identity separation is the primary defence against `file://`
reads of the developer's home directory, downloads to autostart paths,
and any other process-privilege-level attack — `--user-data-dir`
alone does not isolate process write perms.

Launch flags:

```
--remote-debugging-port=<random-port>
--remote-debugging-address=127.0.0.1
--user-data-dir=<ephemeral, session-scoped>
--proxy-server=http://127.0.0.1:<proxy-port>
--proxy-bypass-list="127.0.0.1;localhost;*.test;*.127.0.0.1.sslip.io"
--log-net-log=<session-scoped path>
--no-first-run --no-default-browser-check
--disable-sync --disable-extensions --disable-background-networking
--disable-component-update --disable-features=NativeMessaging,OptimizationHints,AutofillServerCommunication
--download-default-directory=<ephemeral, session-scoped>
```

CDP binds on host loopback only — never on a routable interface or
container bridge gateway. The browser window renders through the
native display stack on each platform (X11/Wayland on Linux native,
Quartz on macOS, WSLg on WSL2 — all transparent to Chrome).

### Actor 2: Agent-browser session bridge

A socat process started by the broker via `docker exec -d` into the
target outer container, listening on `127.0.0.1:9222` inside the
container and forwarding to `host.docker.internal:<random-port>`.

The container's network namespace is the security boundary: socat sits
inside it, so other containers and other host processes cannot reach
that socket. socat itself enforces nothing — it is transport. This is
deliberate; using a host-side iptables/pf ACL as the boundary would
have required two firewall implementations (iptables for Linux/WSL2,
pf for macOS), neither of which can be expressed identically and both
of which add maintenance surface. The netns boundary is free and
already trusted as part of Docker's isolation.

Inside the container, the agent-browser CLI always sees a single
endpoint: `AGENT_BROWSER_CDP_URL=ws://127.0.0.1:9222/...`. Platform
differences are entirely on the host side.

#### Container-side firewall slot (Docker Desktop)

The default-deny OUTPUT chain (ADR 0001) only accepts traffic to
`172.18.0.0/24` (the Docker bridge subnet) and the DNS-driven
allowed-domains ipset. On Docker Desktop (WSL2, macOS),
`host.docker.internal` resolves to a magic IP (typically
`192.168.65.254`) outside both — the in-container socat above would
hit "No route to host" (ICMP admin-prohibited rendered as
`EHOSTUNREACH`) and the CDP smoke test would roll the session back.

The broker opens a session-scoped exception that mirrors the
`allow-for` window pattern (ADR 0009, `start-allow-for-window.sh`):
`start-agent-browser-host-allow <IP> <PORT>` runs in the container via
`docker exec -u root` — no NOPASSWD sudoers added (ADR 0003) — and
inserts `ACCEPT -p tcp -d <IP> --dport <PORT>` immediately before the
final OUTPUT REJECT. Scoping to a single TCP port (the per-session
random CDP port) keeps the firewall hole as narrow as the bridge
actually needs — arbitrary host services on the same magic IP remain
firewalled for the duration of the session. `cmd_stop` and every
rollback path in `cmd_start` close the slot via the matching
`stop-agent-browser-host-allow` helper.

The IP is resolved with `getent ahostsv4 host.docker.internal` (not
`getent hosts`): Docker Desktop on WSL2 returns a dual-stack record,
glibc per RFC 6724 picks IPv6 first, but Docker Desktop only forwards
the IPv4 magic IP and the helper validates dotted IPv4. Forcing v4
here keeps the three consumers — host relay bind, firewall ACCEPT,
in-container `TCP4:` socat upstream — pinned to the same address.

On native Linux + Docker CE the resolved IP is the Docker bridge
gateway, already inside the pre-existing `ACCEPT -d 172.18.0.0/24`
rule — the session-scoped insert is then a harmless idempotent
redundancy. The same code path therefore covers both platforms.

The IP is persisted as `host_allow_ip` in the session state JSON so
`cmd_stop` knows exactly which slot to release even across host
broker restarts; the port is read from the already-persisted
`cdp_port_host` field.

### Actor 3: Agent-browser proxy

A small daemon (Python or Go, ~150 LoC) run as `devbox-agent`,
listening on host loopback `127.0.0.1:<proxy-port>`. Host agent
Chrome's `--proxy-server` forces every outbound HTTP/HTTPS through it.
Two modes:

- **default** — REJECT any CONNECT/GET whose host is not in the
  **Agent-browser allowlist** (`~/.config/devbox/agent-browser-allowed-domains.conf`).
  Bypass list (`localhost`, `*.test`, `*.127.0.0.1.sslip.io`) is set
  on the Chrome side via `--proxy-bypass-list` so dev URLs go direct
  and the proxy never sees them.
- **harvest** — ALLOW + LOG every CONNECT/GET, time-bounded by the
  active **Agent-browser network window**. Mirrors the firewall
  `allow-for` semantics on a different layer.

Mode is read from `~/.local/state/devbox/agent-browser/proxy/active-mode`
and reloaded on SIGHUP. `devbox agent-browser allow-for N` writes the
mode file and signals the proxy.

HTTPS is handled at host granularity (`CONNECT host:443` allow/deny).
No MITM, no cert injection, no CA dance. URL-path granularity is
deliberately out of scope (same rationale as ADR 0009's rejection of
the MITM-proxy option).

**Proxy log format**: JSONL (one JSON object per line) at
`/var/log/devbox/agent-browser/<container>-<ISO>.proxy.log`. Each
line records `{ts, method, host, port, mode, decision, reason?}`.
JSONL is chosen over plain text because the summary generator merges
this stream with the Chrome netlog into a single human-readable
`summary.md` at session teardown; structured records make that merge
straightforward, while remaining one-line-per-event for ad-hoc
`jq` / `grep` inspection.

**Tamper-proof property**: relies on structural isolation, not
ADR 0009's symlink-clobber + filename-reconstruction dance. The proxy
log is written by `devbox-agent` (a host OS user) into a directory
owned by `devbox-agent`; the in-container `node` user has no
filesystem path to that directory (no bind mount, no shared parent).
ADR 0009 needed the elaborate atomic-rename + reconstruction
protocol because the toast IPC required a `pending/` subdirectory
that the in-container UID could write into — an IPC channel that
does not exist here. The agent-browser proxy log is a purely
host-side artefact; a rogue container process cannot reach it. The
user (`vlcak`, UID 1000) reads via group membership on
`devbox-agent`'s log dir.

### Time gates — two independent layers

| Gate | Started by | Closed by | Default state |
|---|---|---|---|
| Agent-browser session (Chrome+bridge exists) | `start` | `stop`, idle timeout, container stop | absent |
| Agent-browser network window (proxy in harvest) | `allow-for N` | `--stop`, timer expiry, session stop | closed |

Agent-browser session can run for hours (Chrome is the audit surface —
the user sees the window on the desktop and can intervene). Network
window is short (default 15 min, matching firewall `allow-for`).

### Cross-platform abstraction

Per-OS differences are confined to `lib/host-platform.sh`:

- `host_platform::detect` → `linux | wsl2 | macos`
- `host_platform::chrome_binary` → path to Chrome
- `host_platform::ensure_agent_user` → idempotent user creation
  (`useradd` on Linux/WSL2, `sysadminctl` on macOS — regular user, not
  underscore-prefixed system user, to avoid LaunchServices/permissions
  edge cases)
- `host_platform::notify <title> <body> <click-target>` → `notify-send`
  on Linux, PowerShell BurntToast on WSL2 (existing pipeline), `osascript`
  on macOS

The outer container's `docker run` always includes
`--add-host=host.docker.internal:host-gateway`. On Docker Desktop this
is redundant; on native Linux it is required. Uniform always.

### Session state

`~/.local/state/devbox/agent-browser/sessions/<container>.json`,
written by the broker:

```json
{
  "container": "easyjukebox-api",
  "chrome_pid": 12345,
  "bridge_pid_in_container": 23456,
  "proxy_pid": 34567,
  "cdp_port_host": 49152,
  "proxy_port_host": 49153,
  "profile_dir": "/var/lib/devbox-agent/profiles/easyjukebox-api-20260519-123456",
  "download_dir": "/var/lib/devbox-agent/downloads/easyjukebox-api-20260519-123456",
  "netlog_path": ".../netlog.json",
  "created_at": "2026-05-19T12:34:56Z",
  "active_network_window": null
}
```

Network window state (when active) is recorded under `active_network_window`
with `started_at`, `expires_at`, and the per-window harvest log path.

At any `devbox agent-browser start`, the broker first sweeps for
orphan processes from a stale session file (Chrome PID dead, bridge
container gone, etc.) and cleans up before launching the new one.

## Considered options

**Chrome inside the devbox container (DinD).** Tempting because the
container's firewall would naturally cover the browser. Rejected
because the visual-audit value (user sees what the agent clicks)
collapses to "user opens a Traefik-routed viewport-stream URL in their
own Chrome", which is less direct, requires WSL/macOS GUI plumbing
through containers, and loses host-native display behaviour. Plus the
container already has heavy footprint (Node, Python, rust, dind) and
adding Chrome's deps doubles image size for a feature most projects
won't use daily.

**The user's personal Chrome via the existing profile.** Rejected
explicitly — CDP has no auth and would give an LLM agent full read of
banking sessions, password manager state, GitHub tokens in localStorage,
and arbitrary host filesystem access via `file://`. Not negotiable.

**Bind CDP on the devproxy bridge gateway (`172.18.0.1`) with iptables
ACL.** Was the initial design. Rejected after the cross-platform
constraint surfaced: macOS Docker Desktop has no `docker0`/`devproxy`
bridge on the host (Docker runs inside a LinuxKit VM), so the same IP
does not exist. Adding pf-on-macOS as a second firewall implementation
to mirror iptables would more than double the maintenance surface of
the security-critical layer.

**Custom CDP proxy with allowlist enforcement** (between container and
Chrome). Considered as the prevention layer before discovering
agent-browser's native `--allowed-domains`. Made redundant by that flag
plus this ADR's network-level proxy.

**DNS-level filtering** (Chrome resolves through a host dnsmasq with
ipsets like the container firewall). Rejected because Chrome caches DNS
aggressively and respects `--host-resolver-rules` only at startup, so
dynamic mode toggling (default ↔ harvest) would require Chrome restarts
on every `allow-for`.

**Host-side broker without OS-user separation** (Chrome as the host
user with a separate `$HOME`). Rejected because `$HOME` is an env var
hint; process-level filesystem permissions are unchanged. CDP
`Browser.setDownloadBehavior` with `downloadPath:
"/home/vlcak/.config/autostart/payload.desktop"` would still write
there. OS identity is the only durable boundary.

**Hard session max-lifetime cap (30–60 min).** Suggested as a defence
against runaway sessions. Deferred from MVP: idle timeout +
explicit-stop + container-stop already cover the common cases, and the
Chrome window on the desktop is a visual reminder. If real use shows
session leaks, revisit.

## Consequences

**Positive:**

- Browser-mediated agent work is possible without giving up the
  default-deny posture: the proxy + agent-browser allowlist + harvest
  window mirror the firewall model on a layer the firewall cannot
  reach.
- The container security model is preserved: no Docker socket exposed,
  no host-loopback access, no shared filesystem with the user's home.
  The new attack surface is one socat socket inside the container's
  netns and one HTTP proxy on host loopback.
- Cross-platform parity is real, not aspirational. The same broker
  logic runs on three platforms; only `lib/host-platform.sh` knows
  about the differences.
- Visual audit is free — the Chrome window appears on the desktop
  through the platform's native display, identical UX everywhere.
- Two independent time gates let session ergonomics (hours-long) and
  network safety (minutes-long) be tuned separately.

**Negative:**

- New host-side process inventory: `devbox-agent` OS user, Chrome,
  proxy daemon, plus one socat per active session. Documented in
  `devbox agent-browser status`.
- Local non-Docker processes on the host can reach the Chrome CDP
  port and the proxy port if they discover them — `127.0.0.1`
  binding is not authorisation. Mitigated by random ports, ephemeral
  profile, separate OS user, and the threat-model observation that a
  malicious local process already has paths to most of the user's
  data. Accepted trade-off vs. shipping a per-platform firewall.
- Even with the proxy and harvest mode, the host browser is the
  agent's exit node: in harvest mode the agent can exfiltrate
  arbitrary data to any URL, and the harvest log captures only the
  hostname, not the URL or body. This is the same property the
  firewall has during `allow-for`. The user must understand that
  opening a network window is a deliberate trust event.
- One-time installer step adds a system user and may prompt for sudo
  (Linux/WSL2) or administrator authentication (macOS). Consistent
  with existing installer behaviour for DNS install / mkcert.
- agent-browser binary must be installed inside the devbox image
  (Dockerfile, per the no-runtime-installs rule). One more thing to
  keep in sync with upstream releases.

## Future work

- `--max-lifetime` cap on sessions, configurable per user. Skip until
  real-use data shows leaks.
- Per-project `agent-browser-allowed-domains.conf` override layered on
  top of the global user-level list. Wait until two projects with
  divergent needs surface.
- `devbox agent-browser review` — fzf picker over the most recent
  harvest log to promote entries into the durable allowlist (mirrors
  the equivalent for firewall `allow-for`).
- Optional URL-path granularity via a built-in MITM proxy with a
  per-session CA trusted only inside the agent profile. Separate
  project, materially heavier; defer until the host-granularity gate
  proves insufficient.
- Status-line integration showing active session + remaining network
  window time.
- Replay tool that reconstructs an agent's browsing path from the
  netlog + harvest log into a human-readable timeline.

## References

- `lib/host-platform.sh` (new) — per-OS dispatch.
- `scripts/agent-browser-broker.sh` (new) — host-side start/stop/status.
- `scripts/agent-browser-proxy.{py,go}` (new) — forward proxy daemon.
- `scripts/deliver-allow-for-notification.sh` — extended to also
  deliver agent-browser session-close and network-window-close toasts
  (single pipeline, paralleling the firewall `allow-for` path).
- `install.sh` — gains `devbox-agent` user creation and Chrome binary
  detection.
- `docker-run.sh` — adds `--add-host=host.docker.internal:host-gateway`
  uniformly.
- `Dockerfile` — bakes in `agent-browser` CLI and the in-container
  socat dependency.
- `CONTEXT.md` — terminology added under "Agent-browser".
- ADR 0001 — the firewall model whose property this ADR mirrors at the
  browser layer.
- ADR 0003 — the privilege-boundary discipline (no sudo in container,
  setup runs from host) this ADR continues.
- ADR 0009 — `allow-for` window pattern this ADR parallels at the
  browser network layer.
