#!/usr/bin/env python3
"""Agent-browser forward proxy daemon (ADR 0010, Actor 3).

Listens on host loopback only, enforces a glob-pattern allowlist against
CONNECT/HTTP-method requests, and writes JSONL decisions to a devbox-agent-
owned log file. Mode is read from a mode-file at startup and re-read on
SIGHUP; allowlist is also re-read on SIGHUP so the user can edit
agent-browser-allowed-domains.conf without restarting Chrome.

Only `default` mode ships in slice 04. The mode file may carry `harvest`
(written by slice 05's `allow-for`); for now we treat any non-default
value identically to `default` — the proxy log will continue to record
the mode field so slice 05 can flip enforcement by changing one branch.

The bypass list (`*.test`, `*.127.0.0.1.sslip.io`, `127.0.0.1`,
`localhost`) is applied on the Chrome side via `--proxy-bypass-list`,
so this proxy never sees dev URLs.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import fnmatch
import json
import logging
import os
import select
import signal
import socket
import socketserver
import sys
import threading
from http.server import BaseHTTPRequestHandler

# Single-pattern entries deeper-than-one level (`*.example.com` matches
# `a.b.example.com`) need a second pattern (`example.com` itself stays
# explicit, but the leading-`*.` form expands to include the bare host).
SPLICE_BUF = 65536
CONNECT_TIMEOUT = 10.0
SOCK_TIMEOUT = 60.0


class ProxyState:
    """Mutable shared state reloaded on SIGHUP."""

    def __init__(self, allowlist_path: str, mode_path: str) -> None:
        self.allowlist_path = allowlist_path
        self.mode_path = mode_path
        self._lock = threading.Lock()
        self._patterns: list[str] = []
        self._mode: str = "default"
        self.reload()

    def reload(self) -> None:
        patterns = _read_allowlist(self.allowlist_path)
        mode = _read_mode(self.mode_path)
        with self._lock:
            self._patterns = patterns
            self._mode = mode

    @property
    def mode(self) -> str:
        with self._lock:
            return self._mode

    def is_allowed(self, host: str) -> bool:
        host_lc = host.lower()
        with self._lock:
            patterns = list(self._patterns)
        for pat in patterns:
            if fnmatch.fnmatchcase(host_lc, pat):
                return True
            # Glob `*.example.com` should match the bare `example.com` too —
            # users expect a single rule to cover the apex and subdomains.
            if pat.startswith("*.") and host_lc == pat[2:]:
                return True
        return False


def _read_allowlist(path: str) -> list[str]:
    patterns: list[str] = []
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for lineno, raw in enumerate(fh, start=1):
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                # Reject anything that looks structurally wrong as a host
                # pattern: whitespace, control chars, slashes (path), or
                # scheme prefixes. Surface a warning and skip the line.
                if any(c.isspace() for c in line) or "/" in line or "://" in line:
                    logging.warning(
                        "allowlist: ignoring malformed line %d: %r", lineno, raw.rstrip()
                    )
                    continue
                if any(ord(c) < 32 for c in line):
                    logging.warning(
                        "allowlist: ignoring control-char line %d", lineno
                    )
                    continue
                patterns.append(line.lower())
    except FileNotFoundError:
        logging.warning("allowlist file not found: %s (treating as empty)", path)
    except OSError as exc:
        logging.warning("allowlist read failed (%s); treating as empty", exc)
    return patterns


def _read_mode(path: str) -> str:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            value = fh.read().strip().lower()
    except FileNotFoundError:
        return "default"
    except OSError as exc:
        logging.warning("mode-file read failed (%s); defaulting to 'default'", exc)
        return "default"
    if value not in ("default", "harvest"):
        logging.warning("mode-file: unknown value %r; treating as 'default'", value)
        return "default"
    return value


class _JsonlLog:
    """Append-only JSONL writer with line-level locking."""

    def __init__(self, path: str) -> None:
        self._path = path
        self._lock = threading.Lock()
        # Open in line-buffered append mode so each decision is on disk
        # promptly; the broker's stop path archives this file and a
        # half-flushed last line would leak through.
        self._fh = open(path, "a", buffering=1, encoding="utf-8")  # noqa: SIM115

    def write(self, record: dict) -> None:
        line = json.dumps(record, ensure_ascii=False)
        with self._lock:
            self._fh.write(line + "\n")

    def close(self) -> None:
        with self._lock:
            try:
                self._fh.close()
            except OSError:
                pass


def _iso_utc_now() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_authority(authority: str, default_port: int) -> tuple[str, int]:
    if authority.startswith("["):
        # bracketed IPv6
        end = authority.find("]")
        if end < 0:
            raise ValueError("malformed IPv6 authority")
        host = authority[1:end]
        rest = authority[end + 1 :]
        if rest.startswith(":"):
            return host, int(rest[1:])
        return host, default_port
    if ":" in authority:
        host, _, port_s = authority.rpartition(":")
        return host, int(port_s)
    return authority, default_port


def _strip_url_host(url: str) -> tuple[str, int, str]:
    # e.g. "http://example.com:8080/path?x=1"
    if "://" in url:
        _, _, rest = url.partition("://")
    else:
        rest = url
    if "/" in rest:
        authority, _, path = rest.partition("/")
        path = "/" + path
    else:
        authority = rest
        path = "/"
    host, port = _parse_authority(authority, 80)
    return host, port, path


class _Handler(BaseHTTPRequestHandler):
    # Quieter default access logging; we have our own JSONL log.
    def log_message(self, format: str, *args) -> None:  # noqa: A002, ARG002
        return

    @property
    def _state(self) -> ProxyState:
        return self.server.proxy_state  # type: ignore[attr-defined]

    @property
    def _jsonl(self) -> _JsonlLog:
        return self.server.proxy_log  # type: ignore[attr-defined]

    def _decision(self, host: str) -> tuple[bool, str | None]:
        mode = self._state.mode
        if mode == "default":
            if self._state.is_allowed(host):
                return True, None
            return False, "no allowlist match"
        # `harvest` is slice 05's territory. For slice 04 we treat it
        # exactly like default so the only-default-ships invariant holds;
        # slice 05 will replace this branch with allow-all + logging.
        if self._state.is_allowed(host):
            return True, None
        return False, "no allowlist match"

    def _log(self, method: str, host: str, port: int, decision: str, reason: str | None) -> None:
        record = {
            "ts": _iso_utc_now(),
            "method": method,
            "host": host,
            "port": port,
            "mode": self._state.mode,
            "decision": decision,
        }
        if reason is not None:
            record["reason"] = reason
        try:
            self._jsonl.write(record)
        except OSError as exc:
            logging.warning("proxy log write failed: %s", exc)

    def _send_403(self, host: str) -> None:
        body = (
            "blocked by devbox agent-browser default mode; open a network "
            "window with `devbox agent-browser allow-for N`. "
            f"target: {host}\n"
        ).encode("utf-8")
        try:
            self.send_response(403, "Forbidden")
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
        except OSError:
            pass

    def do_CONNECT(self) -> None:  # noqa: N802
        try:
            host, port = _parse_authority(self.path, 443)
        except ValueError:
            self.send_error(400, "Bad CONNECT target")
            return
        allowed, reason = self._decision(host)
        self._log("CONNECT", host, port, "allow" if allowed else "deny", reason)
        if not allowed:
            self._send_403(host)
            return
        try:
            upstream = socket.create_connection((host, port), timeout=CONNECT_TIMEOUT)
        except OSError as exc:
            self.send_error(502, f"Upstream connect failed: {exc}")
            return
        try:
            self.send_response(200, "Connection Established")
            self.end_headers()
        except OSError:
            upstream.close()
            return
        self._splice(self.connection, upstream)

    def _do_forward(self) -> None:
        host, port, path = _strip_url_host(self.path)
        method = self.command
        allowed, reason = self._decision(host)
        self._log(method, host, port, "allow" if allowed else "deny", reason)
        if not allowed:
            self._send_403(host)
            return
        try:
            upstream = socket.create_connection((host, port), timeout=CONNECT_TIMEOUT)
        except OSError as exc:
            self.send_error(502, f"Upstream connect failed: {exc}")
            return
        try:
            req_line = f"{method} {path} HTTP/1.1\r\n".encode("ascii")
            upstream.sendall(req_line)
            # Rewrite Proxy-Connection -> Connection; drop hop-by-hop fields.
            saw_host = False
            for header, value in self.headers.items():
                hl = header.lower()
                if hl in ("proxy-connection",):
                    continue
                if hl == "host":
                    saw_host = True
                upstream.sendall(f"{header}: {value}\r\n".encode("latin-1"))
            if not saw_host:
                upstream.sendall(f"Host: {host}\r\n".encode("latin-1"))
            upstream.sendall(b"\r\n")
            length = self.headers.get("Content-Length")
            if length is not None:
                try:
                    remaining = int(length)
                except ValueError:
                    remaining = 0
                while remaining > 0:
                    chunk = self.rfile.read(min(SPLICE_BUF, remaining))
                    if not chunk:
                        break
                    upstream.sendall(chunk)
                    remaining -= len(chunk)
            self._splice(self.connection, upstream, half_close_client=True)
        except OSError as exc:
            logging.warning("forward I/O failed: %s", exc)
            try:
                upstream.close()
            except OSError:
                pass

    do_GET = _do_forward  # noqa: N815
    do_POST = _do_forward  # noqa: N815
    do_HEAD = _do_forward  # noqa: N815
    do_PUT = _do_forward  # noqa: N815
    do_DELETE = _do_forward  # noqa: N815
    do_OPTIONS = _do_forward  # noqa: N815
    do_PATCH = _do_forward  # noqa: N815

    @staticmethod
    def _splice(a: socket.socket, b: socket.socket, half_close_client: bool = False) -> None:
        a.settimeout(SOCK_TIMEOUT)
        b.settimeout(SOCK_TIMEOUT)
        sockets = [a, b]
        try:
            while True:
                rlist, _, xlist = select.select(sockets, [], sockets, SOCK_TIMEOUT)
                if xlist:
                    break
                if not rlist:
                    break
                done = False
                for s in rlist:
                    try:
                        data = s.recv(SPLICE_BUF)
                    except OSError:
                        done = True
                        break
                    if not data:
                        done = True
                        break
                    other = b if s is a else a
                    try:
                        other.sendall(data)
                    except OSError:
                        done = True
                        break
                if done:
                    break
        finally:
            for s in (a, b):
                if s is a and half_close_client:
                    # BaseHTTPRequestHandler still owns `a`; let its
                    # finish() close it. Just shut down the upstream.
                    continue
                try:
                    s.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                try:
                    s.close()
                except OSError:
                    pass


class _ThreadedServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True
    allow_reuse_address = True
    # IPv4 only — we bind to a literal 127.0.0.1 and never want a dual-stack
    # listener that could accept on ::1 or accidentally on routable v6.
    address_family = socket.AF_INET


def _parse_listen(listen: str) -> tuple[str, int]:
    if ":" not in listen:
        raise argparse.ArgumentTypeError(f"--listen must be host:port, got {listen!r}")
    host, _, port_s = listen.rpartition(":")
    try:
        port = int(port_s)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"invalid port: {port_s!r}") from exc
    if host != "127.0.0.1":
        # Hard-enforce loopback binding. ADR 0010 / AC #7 — never on a
        # routable interface. We refuse with a clear error rather than
        # silently rewriting because a misconfigured caller deserves to
        # know.
        raise argparse.ArgumentTypeError(
            f"--listen host must be 127.0.0.1 (got {host!r}); "
            "the agent-browser proxy refuses to bind any other address"
        )
    return host, port


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Agent-browser forward proxy")
    parser.add_argument("--listen", required=True, type=_parse_listen)
    parser.add_argument("--allowlist", required=True)
    parser.add_argument("--mode-file", required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--ready-fd", type=int, default=None,
                        help="when set, write the bound port + newline to this fd "
                             "after the listener is up (used by the broker when "
                             "port 0 is requested)")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.INFO,
        format="agent-browser-proxy: %(message)s",
        stream=sys.stderr,
    )

    host, port = args.listen
    state = ProxyState(args.allowlist, args.mode_file)
    proxy_log = _JsonlLog(args.log)

    try:
        server = _ThreadedServer((host, port), _Handler)
    except OSError as exc:
        logging.error("failed to bind %s:%d: %s", host, port, exc)
        return 1
    server.proxy_state = state  # type: ignore[attr-defined]
    server.proxy_log = proxy_log  # type: ignore[attr-defined]

    bound_host, bound_port = server.server_address[:2]
    logging.info("listening on %s:%d (mode=%s)", bound_host, bound_port, state.mode)

    if args.ready_fd is not None:
        try:
            os.write(args.ready_fd, f"{bound_port}\n".encode("ascii"))
            os.close(args.ready_fd)
        except OSError as exc:
            logging.warning("ready-fd write failed: %s", exc)

    def _on_sighup(_signum: int, _frame: object) -> None:
        logging.info("SIGHUP — reloading allowlist + mode")
        state.reload()
        logging.info("reloaded (mode=%s)", state.mode)

    def _on_term(_signum: int, _frame: object) -> None:
        logging.info("shutdown signal received")
        # shutdown() must run from a different thread than serve_forever.
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGHUP, _on_sighup)
    signal.signal(signal.SIGTERM, _on_term)
    signal.signal(signal.SIGINT, _on_term)

    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        server.server_close()
        proxy_log.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
