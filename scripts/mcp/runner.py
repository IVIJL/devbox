"""The ``devbox-mcp-run`` wrapper core (ADR 0013, issue 07).

Rendered agent config never calls a raw MCP command — it calls this wrapper
(``devbox-mcp-run <server>`` for a global server, or
``devbox-mcp-run --project <full-project-key> <server>`` for a Project-scoped
one). The wrapper is the stable control point ADR 0013 decision 27 asks for:
agent config keeps calling ``devbox-mcp-run`` even if devbox later swaps an
``npx`` launch for a persistent binary.

What the wrapper does, in order:

  1. **Container identity gate** — refuse to run on the host BEFORE touching a
     profile or launching anything (`mcp.identity`).
  2. **Resolve** the named server from the scope-correct canonical profile
     (global profile, or the Project profile for the passed full project key).
  3. **Validate** required env: every declared env NAME must have a value,
     sourced from the scoped secret store (`mcp.secrets`) for secret keys or
     the inherited environment for non-secret keys. Values are NEVER logged.
  4. **exec** the configured argv with the resolved env merged in, so the MCP
     server inherits this process's stdio (the agent talks to it directly).

Error states are clear and actionable (missing server, disabled server,
missing env, malformed profile, missing identity). Secret VALUES never appear
in any message — only env NAMES.
"""

from __future__ import annotations

import os
from typing import Optional

from .identity import require_container
from .profile import global_profile_path, load_profile, project_profile_path
from .secrets import (
    global_secrets_path,
    project_secrets_path,
    read_server_secrets,
)


class RunnerError(RuntimeError):
    """A wrapper failure with a user-actionable, SECRET-FREE message."""


def _resolve_paths(project_key: Optional[str]) -> tuple[str, str, str]:
    """Return (profile_path, secrets_path, scope_label) for the scope.

    A non-empty ``project_key`` selects the Project profile + Project secret
    store keyed by that FULL project key (the same sanitized+hashed basename the
    render path used); an empty/None key selects the global profile + secrets.
    """
    if project_key:
        return (
            project_profile_path(project_key),
            project_secrets_path(project_key),
            f"project ({project_key})",
        )
    return (global_profile_path(), global_secrets_path(), "global")


def _load_server_spec(
    profile_path: str, server_name: str, scope_label: str
) -> dict:
    """Load and validate one server's spec from the canonical profile.

    Raises ``RunnerError`` (never a bare traceback) for the actionable failure
    modes: a malformed profile, an unknown server, or a disabled server.
    """
    try:
        profile = load_profile(profile_path)
    except (OSError, ValueError) as exc:
        raise RunnerError(
            f"cannot read MCP profile for {scope_label}: {exc}"
        ) from exc

    servers = profile.get("servers")
    if not isinstance(servers, dict):
        raise RunnerError(
            f"malformed MCP profile ('servers' missing or not an object) at "
            f"{profile_path}"
        )

    spec = servers.get(server_name)
    if not isinstance(spec, dict):
        known = sorted(n for n in servers if isinstance(servers[n], dict))
        hint = f" Known servers: {', '.join(known)}." if known else ""
        raise RunnerError(
            f"no MCP server named {server_name!r} in the {scope_label} profile "
            f"({profile_path}).{hint}"
        )

    if spec.get("enabled") is False:
        raise RunnerError(
            f"MCP server {server_name!r} is disabled in the {scope_label} "
            "profile; enable it with 'devbox mcp enable' before launching."
        )
    return spec


def _server_argv(spec: dict, server_name: str) -> list[str]:
    """Extract the launch argv from a server spec, or fail clearly."""
    command = spec.get("command")
    argv = command.get("argv") if isinstance(command, dict) else None
    if not isinstance(argv, list) or not argv:
        raise RunnerError(
            f"MCP server {server_name!r} has no launch command "
            "(command.argv) in the profile."
        )
    return [str(a) for a in argv]


def _resolve_env(
    spec: dict, secrets_path: str, server_name: str
) -> dict[str, str]:
    """Build the env overlay for the server, validating every required name.

    Resolution per declared env NAME (the profile carries names + non-secret
    values only):
      * a SECRET key resolves from the scoped 0600 secret store, then falls back
        to the inherited environment;
      * a NON-secret key resolves from the profile's recorded ``env`` map (the
        inline value carried over at import time), then the inherited
        environment, then a value copied into the store.

    Every declared name MUST resolve to a value or the launch is refused with
    a SECRET-FREE message listing the missing NAMES. Secret VALUES are read
    into memory only and never logged or returned in any error.
    """
    env_keys = spec.get("envKeys")
    secret_env_keys = spec.get("secretEnvKeys")
    env_keys = [str(k) for k in env_keys] if isinstance(env_keys, list) else []
    secret_keys = (
        {str(k) for k in secret_env_keys}
        if isinstance(secret_env_keys, list)
        else set()
    )
    # secretEnvKeys is documented as a SUBSET of envKeys; tolerate a secret key
    # that was not also listed in envKeys so a required credential is never
    # silently skipped.
    all_keys = list(dict.fromkeys([*env_keys, *sorted(secret_keys)]))

    stored = read_server_secrets(secrets_path, server_name) or {}
    # Non-secret values carried in the profile (never secrets — apply filters
    # them, and a secret key takes the store path below regardless).
    profile_env = spec.get("env")
    profile_env = profile_env if isinstance(profile_env, dict) else {}

    overlay: dict[str, str] = {}
    missing: list[str] = []
    for key in all_keys:
        if key in secret_keys and key in stored:
            overlay[key] = stored[key]
        elif key not in secret_keys and key in profile_env:
            overlay[key] = str(profile_env[key])
        elif key in os.environ:
            overlay[key] = os.environ[key]
        elif key in stored:
            # A non-secret key copied into the store is still a usable value.
            overlay[key] = stored[key]
        else:
            missing.append(key)

    if missing:
        # NAMES only — never values.
        raise RunnerError(
            f"MCP server {server_name!r} is missing required env value(s): "
            f"{', '.join(missing)}. Set them in the environment, or re-import "
            "the server so devbox copies the credential into its secret store. "
            "(Values are never printed.)"
        )
    return overlay


def run(server_name: str, project_key: Optional[str] = None) -> int:
    """Resolve and launch one MCP server through the wrapper.

    Never returns on success — it ``exec``s the MCP command so the server
    inherits this process's stdio (the agent speaks MCP to it directly). On any
    actionable failure it raises ``RunnerError`` with a SECRET-FREE message.
    """
    # 1. Container identity gate — refuse on the host before anything else.
    require_container()

    profile_path, secrets_path, scope_label = _resolve_paths(project_key)
    spec = _load_server_spec(profile_path, server_name, scope_label)
    argv = _server_argv(spec, server_name)
    overlay = _resolve_env(spec, secrets_path, server_name)

    # Merge the resolved env over the inherited environment and exec. exec
    # replaces this process so the MCP server owns stdio; on success this call
    # does not return.
    child_env = dict(os.environ)
    child_env.update(overlay)
    try:
        os.execvpe(argv[0], argv, child_env)
    except OSError as exc:
        raise RunnerError(
            f"failed to launch MCP server {server_name!r} "
            f"(command {argv[0]!r}): {exc}"
        ) from exc
    # os.execvpe never returns on success; this line is unreachable but keeps a
    # well-typed return for static checkers.
    return 0  # pragma: no cover
