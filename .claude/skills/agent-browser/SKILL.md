---
name: agent-browser
description: Drive a real Chrome on the host from inside a devbox container to debug UI changes, read JS console errors, take screenshots of the project's dev URL, and inspect network failures. Use whenever the user asks to look at, screenshot, click through, or diagnose what their running app does in a browser. Two time gates — Agent-browser session (Chrome lifecycle) and Agent-browser network window (default-deny proxy in harvest mode) — must both be understood before reaching for external sites.
---

# Agent-browser

`devbox agent-browser` launches a **Host agent Chrome** on the host (under a dedicated `devbox-agent` OS user) and tunnels CDP into the project's container through an **Agent-browser session bridge**. The container's default-deny firewall is preserved at the network layer by the **Agent-browser proxy** in front of Chrome. See `docs/adr/0010-agent-browser-host-broker-and-proxy.md` and the **Agent-browser** section of `CONTEXT.md` for the terminology this skill uses.

## When to invoke

Reach for `devbox agent-browser` when the user asks for anything that needs to see, click through, or instrument the live application:

- "Screenshot the dashboard at `http://3000.my-app.test`"
- "Why is the form throwing a 500? Open the network tab and check the failing request."
- "Read the JS console — there's a hydration error somewhere."
- "Walk through the signup flow and tell me where it breaks."
- "Take an annotated screenshot of each click so I can review."
- "Verify the OG image preview on Facebook's debugger for my staging URL."

Do not reach for it for: pure HTTP testing (use `curl`), API contract checks (use the project's test suite), or anything that doesn't need a real DOM / paint.

## The two-gate model

`agent-browser` has two independent time gates. Mistaking one for the other is the most common skill failure.

**Agent-browser session** — the Chrome + bridge lifecycle.

- Started by `devbox agent-browser start <project>`.
- While open, the Agent-browser proxy is in **default mode** (REJECT anything not in the Agent-browser allowlist or the local-dev bypass list).
- Bypass list (`localhost`, `*.test`, `*.127.0.0.1.sslip.io`) is set on the Chrome side — dev URLs go direct and never touch the proxy.
- Closed by `devbox agent-browser stop <project>`, idle timeout, or container teardown.

**Agent-browser network window** — a time-bounded sub-state inside an active session.

- Started by `devbox agent-browser allow-for <minutes> <project>`.
- Flips the Agent-browser proxy into **harvest mode**: ALLOW + LOG every CONNECT/GET while open.
- Closed by `devbox agent-browser allow-for --stop <project>`, timer expiry, or session stop.
- Default duration 15 min, capped at 24 h.

**CDP bridge plumbing.** Inside the container, the `agent-browser` CLI is shadowed by a thin devbox wrapper that auto-issues `connect 9222` against the Agent-browser session bridge on the first Chrome-bound call after `devbox agent-browser start`. You do not need to run `agent-browser connect 9222` yourself. Power-user invocations that put global flags after the verb or use uncommon options like `--state` may bypass auto-connect — in those edge cases, run `agent-browser <global-flags> connect 9222` once and the upstream CLI takes it from there.

**Decision rule.** Before any navigation, ask: "Is the target URL a project dev URL (`*.test`, `*.127.0.0.1.sslip.io`, `localhost`)?"

- **Yes** — proceed. No window needed; the bypass list lets the request through directly.
- **No** — check the Agent-browser allowlist (`~/.config/devbox/agent-browser-allowed-domains.conf`). If the host is listed, proceed. Otherwise, the proxy will deny the request in default mode. Open an Agent-browser network window with `allow-for` before navigating, then close it when done.

Opening a network window is a deliberate trust event — the host browser becomes an unconstrained exit node for the duration. Keep windows short.

## Reading the summary

When a session ends, the host writes three files under `/var/log/devbox/agent-browser/<container>-<ISO>.*`:

- `netlog.json` — Chrome's native netlog (raw, for forensics).
- `proxy.log` — JSONL of every proxy decision.
- `summary.md` — human-readable digest.

Read `summary.md` after `stop` and surface anything alarming to the user:

- **Hard fails** — `file://`, `chrome://`, native-messaging attempts, denied downloads. These should never happen in a clean session; if they appear, flag prominently.
- **Out-of-allowlist hosts during harvest** — these are candidates the user may want to promote to the durable Agent-browser allowlist, or evidence the agent wandered further than intended.
- **Unexpected large uploads** — POST/PUT byte counts well above what the task should have produced. Worth surfacing as a possible exfil signal.
- **Session stats** — visit count, downloads, total bytes. Mention only if relevant to the user's question.

## Concrete examples

### Example 1 — dev URL only, no network window

User: "The form on `http://5173.my-app.test/signup` is returning a 500 — can you screenshot it and check the network tab?"

```sh
# `devbox agent-browser ...` runs on the host; the `agent-browser` CLI inside
# the container drives Chrome via the bridge once the session is up. The exact
# subcommand names below are illustrative — defer to `agent-browser --help`
# inside the container for the upstream CLI surface.
devbox agent-browser start my-app
agent-browser navigate http://5173.my-app.test/signup
agent-browser screenshot --output /tmp/signup-500.png
agent-browser network --filter "status>=500"
devbox agent-browser stop my-app
```

`*.test` is in Chrome's `--proxy-bypass-list`, so no Agent-browser network window is needed. Report screenshot + failing-request summary + anything notable from `summary.md` (e.g. hard fails would be unexpected here — flag if any).

### Example 2 — external site, network window required

User: "Verify the OG image preview for my deployed staging URL on Facebook's debugger."

```sh
devbox agent-browser start my-app
# Facebook is not a dev URL and not in the default allowlist — open a 5-minute window:
devbox agent-browser allow-for 5 my-app
agent-browser navigate https://developers.facebook.com/tools/debug/?q=https://staging.my-app.example
agent-browser screenshot --output /tmp/og-debug.png
devbox agent-browser allow-for --stop my-app
devbox agent-browser stop my-app
```

Report the screenshot and what the OG preview showed. Read `summary.md` — surface the harvest hosts so the user can decide whether to promote any to the durable allowlist.

## Terminology pointer

Use the project terms from `CONTEXT.md` verbatim. Do not invent shorthand.

- Say **Agent-browser session** (Chrome+bridge lifecycle), not "chrome session" or "browser bridge".
- Say **Agent-browser network window**, not "browser allow-for" or "agent allow-for".
- Say **Host agent Chrome**, not "personal Chrome" or "shared Chrome" — ADR 0010 explicitly rejects driving the user's personal Chrome.
- Say **Agent-browser proxy**, not "agent proxy" or "browser proxy".
- Say **Agent-browser allowlist** when referring to `~/.config/devbox/agent-browser-allowed-domains.conf` — it is distinct from the firewall **Allowlist**.

The firewall `allow-for` and the Agent-browser `allow-for` parallel each other but act on different layers. Be precise about which one you mean.
