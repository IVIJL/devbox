"""Read inherited env VALUES from a source agent config (ADR 0013, issue 05).

The candidate model (`mcp.candidate`) is deliberately secret-free: providers
record env-variable NAMES only, never values, so discovery output can be
emitted without redaction. But hassle-free import needs to COPY those values
into the devbox secret store at apply time.

This module is the one, narrowly-scoped place that re-reads the original source
config to recover the env values for a server the user explicitly chose to
import. It is invoked ONLY by the apply path, returns values purely in memory,
and never logs or prints them. Everything downstream (profile, summary, JSON)
sees names only.

Why re-read instead of carrying values on the candidate: keeping values off the
candidate means every other code path (discovery, list, merge, classification,
text/JSON rendering) is structurally incapable of leaking a secret. The cost is
this single deliberate read, gated behind an explicit apply selection.
"""

from __future__ import annotations

import json
import os
from typing import Any, Optional

from .candidate import Candidate

_toml: Any = None
try:  # Python 3.11+ stdlib.
    import tomllib as _toml  # type: ignore[no-redef]
except ModuleNotFoundError:  # pragma: no cover - environment dependent
    try:
        import tomli as _toml  # type: ignore[no-redef]
    except ModuleNotFoundError:
        _toml = None


def _claude_env(cand: Candidate) -> dict[str, str]:
    """Recover the ``env`` map for a Claude server from its source file."""
    path = cand.source_path
    if not os.path.isfile(path):
        return {}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    if cand.source_scope == "project" and cand.source_project:
        projects = data.get("projects")
        record = projects.get(cand.source_project) if isinstance(projects, dict) else None
        block = record.get("mcpServers") if isinstance(record, dict) else None
    else:
        block = data.get("mcpServers")
    spec = block.get(cand.name) if isinstance(block, dict) else None
    env = spec.get("env") if isinstance(spec, dict) else None
    if not isinstance(env, dict):
        return {}
    return {str(k): str(v) for k, v in env.items()}


def _codex_env(cand: Candidate) -> dict[str, str]:
    """Recover the ``env`` map for a Codex server from its source TOML."""
    if _toml is None:
        return {}
    path = cand.source_path
    if not os.path.isfile(path):
        return {}
    try:
        with open(path, "rb") as fh:
            data = _toml.load(fh)
    except (OSError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    servers = data.get("mcp_servers")
    table = servers.get(cand.name) if isinstance(servers, dict) else None
    env = table.get("env") if isinstance(table, dict) else None
    if not isinstance(env, dict):
        return {}
    return {str(k): str(v) for k, v in env.items()}


def read_secret_values(cand: Candidate) -> dict[str, str]:
    """Return the secret env name -> value map for a candidate, in memory only.

    Reads the candidate's original source config and returns only the values for
    the names already flagged as ``secret_env_keys`` on the candidate. Names not
    flagged secret (e.g. ``LOG_LEVEL``) are NOT copied — devbox copies only what
    it must to make the server work without re-entry of credentials. Returns an
    empty dict when the source cannot be read or carries no matching env.

    NEVER log or print the result.
    """
    secret_keys = set(cand.command.secret_env_keys)
    if not secret_keys:
        return {}
    if cand.provider == "codex":
        env = _codex_env(cand)
    else:
        env = _claude_env(cand)
    return {k: v for k, v in env.items() if k in secret_keys}
