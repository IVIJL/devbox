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
