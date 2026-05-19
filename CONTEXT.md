# Devbox

Devbox is a Linux-container development environment that runs each project
behind a default-deny outbound firewall. The container's outbound traffic is
restricted by domain, and host-side commands manage the firewall, the
shared resolver, and the optional HTTPS layer.

## Language

### Firewall

**Allowlist**:
The user-curated set of domains in `~/.config/devbox/allowed-domains.conf`
whose resolved IPs the firewall permits permanently.
_Avoid_: whitelist, ACL, rules

**Allowed-domains ipset**:
The Netfilter set named `allowed-domains` that dnsmasq populates at lookup
time from the **Allowlist**. Persistent across the container's lifetime.

**Default-deny**:
The baseline iptables policy: outbound traffic is `REJECT`ed unless its
destination IP is in an accepting ipset. The system's safety floor.

**DNS pinning**:
The iptables policy that restricts outbound DNS (port 53 UDP/TCP, port 853
DoT) to the in-container dnsmasq on `127.0.0.1`. Forces all name resolution
through the audited resolver.
_Avoid_: DNS lockdown, resolver enforcement

### Allow-for window

**Allow-for window**:
A time-bounded session, started by `devbox allow-for`, during which
**non-allowlist** domains are passively allowed and recorded. Ends
automatically after the configured duration (default 15 min).
_Avoid_: temporary allow, firewall open mode, harvest mode

**Harvest pool**:
The ephemeral Netfilter set named `harvest-pool`, populated by dnsmasq's
catch-all `ipset=//harvest-pool` directive during an active **Allow-for
window**. Destroyed at window teardown.
_Avoid_: catch-all ipset, ephemeral allowlist

**Harvest log**:
A per-run, tamper-proof plain-text file written at window teardown to
`/var/log/devbox/allow-for/<container>-<timestamp>.log`. Contains the
unique set of domains queried during the window that were not covered by
the **Allowlist**.
_Avoid_: audit log, harvest report, capture file

**Sentinel state**:
The root-owned file inside the container (`/etc/devbox-shared/.allow-for.state`)
recording the active window's `started_at`, `expires_at`, and daemon PID.
Source of truth for status queries.

### Agent-browser

**Agent-browser session**:
A long-lived host-side state, started by `devbox agent-browser start
<project>` and ended by `... stop`. While active, exactly one **Host
agent Chrome** runs on the host and exactly one **Container** can reach
its CDP endpoint through an in-container bridge socket. Closes on
explicit `stop`, idle timeout (`AGENT_BROWSER_IDLE_TIMEOUT_MS`), or
container teardown.
_Avoid_: chrome session, browser bridge

**Host agent Chrome**:
The dedicated Chrome instance launched on the host by the **Agent-browser
session** broker. Runs as a distinct OS user (`devbox-agent` on all
three platforms), with an ephemeral `--user-data-dir`, hardened launch
flags (no extensions, no native messaging, no sync, no `file://`
access), and `--log-net-log=<path>`. Binds CDP on the host's loopback
(`127.0.0.1:<random-port>`) — never on a routable interface. All
outbound HTTP/HTTPS is forced through the **Agent-browser proxy** via
`--proxy-server`.
_Avoid_: personal Chrome, shared Chrome

**Agent-browser session bridge**:
The per-session socat process running inside the outer **Container**'s
network namespace, forwarding `127.0.0.1:9222` (inside the container)
to `host.docker.internal:<random-port>` (the **Host agent Chrome**'s
CDP). The container's network namespace is the security boundary: no
other container or process can see this socket. socat is the
transport, not the gate.
_Avoid_: cdp tunnel, browser forwarder

**Agent-browser network window**:
A time-bounded sub-state of an **Agent-browser session**, started by
`devbox agent-browser allow-for <minutes>`. While open, the
**Agent-browser proxy** is in **harvest mode**: any host the browser
contacts is allowed and logged, paralleling the firewall **Allow-for
window**. Outside this sub-window, the proxy denies everything not in
the **Agent-browser allowlist** or the local-dev bypass list.
_Avoid_: browser allow-for, agent allow-for

**Agent-browser proxy**:
The host-side HTTP forward proxy daemon, run by `devbox-agent`, that
gates all of **Host agent Chrome**'s outbound traffic. Reloadable via
SIGHUP. Has two modes:
- **default mode** — REJECT everything except the **Agent-browser
  allowlist** and the bypass list (`localhost`, `*.test`,
  `*.127.0.0.1.sslip.io`)
- **harvest mode** — ALLOW + LOG every CONNECT/GET, time-bounded by
  the active **Agent-browser network window**
_Avoid_: agent proxy, browser proxy

**Agent-browser allowlist**:
The set of domain patterns in
`~/.config/devbox/agent-browser-allowed-domains.conf`, distinct from
the firewall **Allowlist**. Enforced at two points:
1. **Agent-browser proxy** (network gate — CONNECT/GET host check)
2. agent-browser's native `--allowed-domains` flag (page-level
   navigation gate — a structured error reaches the agent on denial,
   useful for LLM feedback)
Read at session start, propagated into the **Container** via
`AGENT_BROWSER_ALLOWED_DOMAINS`.
_Avoid_: browser allowlist, navigation allowlist

**Netlog**:
The Chrome-native `--log-net-log=` JSON file written by **Host agent
Chrome** for the lifetime of a session. Archived at session teardown
to `/var/log/devbox/agent-browser/<container>-<timestamp>.netlog.json`
and summarized into a human-readable `summary.md` (visited hosts,
out-of-allowlist requests, downloads, suspicious flags).
_Avoid_: chrome log, browser audit

### Project / container

**Project**:
A user codebase mounted into a devbox container. Identified by the
sanitized basename of its host path (see ADR 0005).

**Container**:
The Docker container `devbox-<project>` that runs the project's dev
environment. Each project gets exactly one container at a time.

## Relationships

- A **Project** has exactly one **Container** at a time.
- An **Allowlist** is shared across all of a user's **Containers**
  (bind-mounted `:ro` from `~/.config/devbox/allowed-domains.conf`).
- An **Allow-for window** runs in exactly one **Container** at a time;
  starting a second window in the same container *resets the clock* (does
  not stack).
- An **Allow-for window** has exactly one **Harvest pool** for its lifetime
  and produces exactly one **Harvest log** at teardown.
- A domain added via `devbox allow` during an active window joins the
  **Allowlist** permanently; the **Harvest pool** keeps it (harmlessly
  redundant) until window teardown.
- An **Agent-browser session** runs in exactly one **Container** at a
  time and is bound to exactly one **Host agent Chrome** and exactly
  one **Agent-browser session bridge** for its lifetime; all three die
  together at session teardown.
- An **Agent-browser session** can contain at most one active
  **Agent-browser network window**. Starting a second `allow-for`
  during an active window *resets the clock* (parallel to the firewall
  **Allow-for window**).
- The **Agent-browser allowlist** is shared across all of a user's
  **Containers**, like the firewall **Allowlist**, but its enforcement
  points are the **Agent-browser proxy** (network) and agent-browser
  CLI (page navigation), not the firewall.
- The **Agent-browser proxy** is the single network exit point for
  **Host agent Chrome**. Chrome cannot reach the internet by any other
  path; the `--proxy-server` flag is non-negotiable.

## Example dialogue

> **Dev:** "I'm about to let an LLM agent run a research task in `myapp`.
> Can I just open the firewall for 30 minutes?"
>
> **Maintainer:** "Don't open the firewall — start an **Allow-for window**.
> Run `devbox allow-for 30` in the project. The window stays in
> **default-deny** mode for everything the **Allowlist** doesn't cover, but
> any domain the agent queries through the resolver lands in the **Harvest
> pool** and gets through for the rest of the window. When the window
> closes, you get a clickable Windows toast plus a **Harvest log** listing
> every non-allowlist domain. Hardcoded-IP traffic stays blocked the whole
> time, thanks to **DNS pinning**."

## Flagged ambiguities

- "Harvest mode" and "temporary allow" were both used informally for the
  **Allow-for window**. Resolved: canonical term is **Allow-for window**.
- "Catch-all ipset" was used interchangeably with **Harvest pool**.
  Resolved: prefer **Harvest pool** for the named concept; "catch-all"
  describes only the dnsmasq directive that populates it.
