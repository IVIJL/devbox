"""The MCP relay — the reworked ``devbox-mcp-run`` (ADR 0014, issue 15).

Rendered agent config still calls ``devbox-mcp-run <server>`` (or
``devbox-mcp-run --project <key> <server>``) — the stable control point ADR
0013 established and ADR 0014 preserves. But the command no longer execs the MCP
server itself. Instead it is a thin **stdio<->socket relay** running as the
agent user ``node``:

  1. connect to the broker's unix socket (a node-connectable location, separate
     from any 0700 secret directory — connecting exposes only a pipe);
  2. send the handshake naming the requested server (and Project key), receive
     the broker's accept/refuse reply;
  3. on accept, proxy this process's stdin/stdout to the socket so the agent
     speaks MCP straight through to the server the broker spawned under the
     ``devbox-mcp`` UID.

Because the server runs under a different UID behind the broker, the agent never
becomes the server process and never sees its environment (secrets, issue 16).
The relay carries only the MCP stdio stream.

The Container identity gate still applies: ``devbox-mcp-run`` is container-only,
so the relay refuses on the host before touching the socket.
"""

from __future__ import annotations

import os
import selectors
import socket
import sys
from typing import Optional

from .broker import socket_path
from .identity import require_container
from .protocol import (
    ProtocolError,
    decode_reply,
    encode_request,
    read_line,
)

_PROXY_CHUNK = 64 * 1024


class RelayError(RuntimeError):
    """A relay failure with a user-actionable, SECRET-FREE message."""


def _connect(path: str) -> socket.socket:
    """Connect to the broker socket, or fail with an actionable message."""
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(path)
    except OSError as exc:
        sock.close()
        raise RelayError(
            f"cannot reach the devbox MCP broker at {path}: {exc}. "
            "The broker starts with the Container; if this persists, restart "
            "the Container."
        ) from exc
    return sock


def _proxy(sock: socket.socket, stdin_fd: int, stdout_fd: int) -> None:
    """Bidirectionally proxy stdin/stdout <-> the broker socket until EOF.

    A single-threaded selector loop avoids spawning threads in the per-server
    relay process (one runs per MCP server the agent uses). When the agent's
    stdin closes we half-close the socket's write side so the server sees EOF;
    when the socket closes (server exited) we stop.
    """
    sel = selectors.DefaultSelector()
    sock.setblocking(False)
    os.set_blocking(stdin_fd, False)
    sel.register(sock, selectors.EVENT_READ, "sock")
    sel.register(stdin_fd, selectors.EVENT_READ, "stdin")

    stdin_open = True
    try:
        while True:
            for key, _mask in sel.select():
                if key.data == "sock":
                    try:
                        data = sock.recv(_PROXY_CHUNK)
                    except (BlockingIOError, InterruptedError):
                        continue
                    if not data:
                        return  # server/broker closed: done
                    _write_all_fd(stdout_fd, data)
                elif key.data == "stdin":
                    try:
                        data = os.read(stdin_fd, _PROXY_CHUNK)
                    except (BlockingIOError, InterruptedError):
                        continue
                    if not data:
                        # Agent closed stdin: signal EOF to the server, then
                        # stop watching stdin but keep draining the socket.
                        stdin_open = False
                        sel.unregister(stdin_fd)
                        try:
                            sock.shutdown(socket.SHUT_WR)
                        except OSError:
                            pass
                        continue
                    _send_all(sock, data)
    except OSError:
        # A broken pipe in either direction ends the session cleanly.
        pass
    finally:
        sel.close()
        if stdin_open:
            try:
                sock.shutdown(socket.SHUT_WR)
            except OSError:
                pass


def _write_all_fd(fd: int, data: bytes) -> None:
    """Write all of ``data`` to a (possibly non-blocking) fd."""
    view = memoryview(data)
    while view:
        try:
            written = os.write(fd, view)
            view = view[written:]
        except (BlockingIOError, InterruptedError):
            continue


def _send_all(sock: socket.socket, data: bytes) -> None:
    """Send all of ``data`` over a non-blocking socket."""
    view = memoryview(data)
    while view:
        try:
            sent = sock.send(view)
            view = view[sent:]
        except (BlockingIOError, InterruptedError):
            continue


def run(server_name: str, project_key: Optional[str] = None) -> int:
    """Relay one MCP server's stdio through the broker. Returns an exit code.

    The same signature as the ADR 0013 runner so ``mcp.cli run`` is unchanged.
    On any actionable failure raises :class:`RelayError` with a SECRET-FREE
    message; on a clean session returns 0.
    """
    # Container identity gate — refuse on the host before opening any socket.
    require_container()

    path = socket_path()
    sock = _connect(path)
    try:
        sock.sendall(encode_request(server_name, project_key))
        try:
            reply = read_line(sock.recv)
            ok, error = decode_reply(reply)
        except ProtocolError as exc:
            raise RelayError(
                f"malformed reply from the devbox MCP broker: {exc}"
            ) from exc
        if not ok:
            raise RelayError(
                f"the devbox MCP broker refused server {server_name!r}: "
                f"{error or 'no reason given'}"
            )
        _proxy(sock, sys.stdin.fileno(), sys.stdout.fileno())
        return 0
    finally:
        try:
            sock.close()
        except OSError:
            pass
