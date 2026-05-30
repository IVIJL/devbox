"""Wire protocol shared by the MCP broker and relay (ADR 0014, issue 15).

The relay (``devbox-mcp-run``, running as ``node``) and the broker (running as
``devbox-mcp``) talk over a unix-domain stream socket. The conversation has two
phases:

  1. **Handshake** — the relay sends exactly one newline-terminated JSON object
     naming the server it wants (and the optional Project key). The broker
     replies with one newline-terminated JSON object reporting whether it
     accepted the request. No credential is ever carried in either direction:
     the handshake names a server, the reply reports a status.
  2. **Stream** — on acceptance, both sides switch to a raw byte proxy: the
     relay's stdin is forwarded to the spawned server's stdin and the server's
     stdout is forwarded back to the relay's stdout. This is the MCP stdio
     stream; the agent speaks MCP straight through to the server and never sees
     the server's environment (the server runs under a different UID).

Framing rationale: a single ``\\n``-terminated JSON line is enough for the
handshake because the request and the reply are each a small, flat object. The
broker reads up to a bounded number of bytes for the handshake so a hostile or
buggy client cannot make it buffer without limit before the stream phase.

SECURITY: the handshake intentionally carries names only (server name, project
key). Secret VALUES never cross this socket — they are injected by the broker
into the spawned process's environment (issue 16), out of band of this protocol.
"""

from __future__ import annotations

import json
from typing import Any, Optional

# Upper bound on the handshake line, in bytes. The handshake is a small flat
# JSON object (a server name + an absolute path); 64 KiB is far more than any
# legitimate request needs and bounds the broker's pre-stream buffering against
# a client that never sends a newline.
MAX_HANDSHAKE_BYTES = 64 * 1024


class ProtocolError(RuntimeError):
    """A malformed or oversized handshake on the broker/relay socket."""


def encode_request(server: str, project_key: Optional[str]) -> bytes:
    """Encode a relay -> broker handshake request (server name + scope).

    ``project_key`` is the absolute host path for a Project-scoped server, or
    ``None``/empty for a global one. Only names cross the wire — never a value.
    """
    obj: dict[str, Any] = {"server": str(server)}
    if project_key:
        obj["project"] = str(project_key)
    return (json.dumps(obj, separators=(",", ":")) + "\n").encode("utf-8")


def decode_request(line: bytes) -> tuple[str, Optional[str]]:
    """Decode a relay -> broker handshake into ``(server, project_key)``.

    Raises :class:`ProtocolError` for anything that is not a JSON object with a
    non-empty string ``server`` field, so the broker rejects junk before it
    touches a profile or spawns anything.
    """
    try:
        obj = json.loads(line.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as exc:
        raise ProtocolError(f"handshake is not valid JSON: {exc}") from exc
    if not isinstance(obj, dict):
        raise ProtocolError("handshake is not a JSON object")
    server = obj.get("server")
    if not isinstance(server, str) or not server:
        raise ProtocolError("handshake missing a non-empty 'server' name")
    project = obj.get("project")
    if project is not None and not isinstance(project, str):
        raise ProtocolError("handshake 'project' must be a string when present")
    return server, (project or None)


def encode_reply(ok: bool, error: Optional[str] = None) -> bytes:
    """Encode a broker -> relay status reply (accepted, or refused + reason).

    The ``error`` text is SECRET-FREE by construction (the broker only ever puts
    server/scope names and structural failures here), so it is safe to surface
    to the agent. It is never a credential value.
    """
    obj: dict[str, Any] = {"ok": bool(ok)}
    if not ok and error:
        obj["error"] = str(error)
    return (json.dumps(obj, separators=(",", ":")) + "\n").encode("utf-8")


def decode_reply(line: bytes) -> tuple[bool, Optional[str]]:
    """Decode a broker -> relay reply into ``(ok, error)``."""
    try:
        obj = json.loads(line.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as exc:
        raise ProtocolError(f"broker reply is not valid JSON: {exc}") from exc
    if not isinstance(obj, dict):
        raise ProtocolError("broker reply is not a JSON object")
    ok = obj.get("ok")
    if not isinstance(ok, bool):
        raise ProtocolError("broker reply missing boolean 'ok'")
    error = obj.get("error")
    if error is not None and not isinstance(error, str):
        raise ProtocolError("broker reply 'error' must be a string when present")
    return ok, (error or None)


def read_line(recv, max_bytes: int = MAX_HANDSHAKE_BYTES) -> bytes:
    """Read one ``\\n``-terminated line from a blocking byte stream.

    ``recv`` is any callable taking a byte count and returning bytes (e.g.
    ``socket.recv`` or ``file.read``); reading is one byte short of greedy so
    the bytes after the newline (the start of the raw MCP stream) stay in the
    socket buffer for the proxy phase rather than being swallowed here.

    Returns the line WITHOUT the trailing newline. Raises
    :class:`ProtocolError` if the peer closes before a newline or the line
    exceeds ``max_bytes`` (bounding pre-stream buffering).
    """
    buf = bytearray()
    while True:
        chunk = recv(1)
        if not chunk:
            raise ProtocolError("connection closed before handshake completed")
        if chunk == b"\n":
            return bytes(buf)
        buf.extend(chunk)
        if len(buf) > max_bytes:
            raise ProtocolError("handshake exceeded maximum length")
