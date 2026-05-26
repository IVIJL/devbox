"""JSON/text entry point for `devbox mcp` (ADR 0013, issues 01-02).

The shell dispatcher `scripts/mcp-cli.sh` owns arg parsing and process flow; it
shells out to this module for both the machine-readable `--json` paths and the
human-readable candidate tables so the candidate-model serialization and
rendering live in one place (the Python core). Invoked as:

    python3 -m mcp.cli import-json        [--project <key> ...] [--all] [--no-global]
    python3 -m mcp.cli import-text        [--project <key> ...] [--all] [--no-global]
    python3 -m mcp.cli list-inherited-json [--project <key> ...] [--all] [--no-global]

with `scripts/` on PYTHONPATH so `import mcp` resolves to this package.

Issue 02 wires the Claude Code provider into discovery. Scope:

  * default: global config + the project keys passed via `--project`
    (the dispatcher resolves the current Project to its Claude record key);
  * `--all`: every known Claude project record;
  * `--no-global`: skip the top-level global `mcpServers` block.

Read-only and secret-safe: no field carries a secret value, so JSON and text
output can be emitted directly without a redaction pass.
"""

from __future__ import annotations

import json
import sys
from typing import Optional

from . import import_result, inherited_list_result
from .candidate import Candidate
from .providers import ClaudeProvider


def _emit(payload: dict) -> int:
    json.dump(payload, sys.stdout, indent=2, sort_keys=False)
    sys.stdout.write("\n")
    return 0


class _Scope:
    def __init__(self) -> None:
        self.project_keys: list[str] = []
        self.all_projects: bool = False
        self.include_global: bool = True


def _parse_scope(argv: list[str]) -> Optional[_Scope]:
    """Parse the shared scope flags. Returns None on a parse error."""
    scope = _Scope()
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--all":
            scope.all_projects = True
        elif arg == "--no-global":
            scope.include_global = False
        elif arg == "--project":
            i += 1
            if i >= len(argv):
                sys.stderr.write("mcp.cli: --project requires a value\n")
                return None
            scope.project_keys.append(argv[i])
        else:
            sys.stderr.write(f"mcp.cli: unknown argument {arg!r}\n")
            return None
        i += 1
    return scope


def _discover(scope: _Scope) -> list[Candidate]:
    provider = ClaudeProvider()
    return provider.discover(
        project_keys=scope.project_keys,
        include_global=scope.include_global,
        all_projects=scope.all_projects,
    )


def _render_text(candidates: list[Candidate]) -> int:
    """Human-readable discovery report (no secret values, names only)."""
    if not candidates:
        sys.stdout.write("No Inherited MCP servers detected in the selected scope.\n")
        return 0

    importable = [c for c in candidates if c.classification.placement != "excluded"]
    excluded = [c for c in candidates if c.classification.placement == "excluded"]

    sys.stdout.write(
        f"Discovered {len(candidates)} Inherited MCP server(s) "
        f"({len(importable)} importable, {len(excluded)} excluded):\n"
    )
    for cand in candidates:
        scope_label = cand.source_scope
        if cand.source_project:
            scope_label = f"{scope_label} ({cand.source_project})"
        sys.stdout.write("\n")
        sys.stdout.write(f"  {cand.name}\n")
        sys.stdout.write(f"    provider : {cand.provider}\n")
        sys.stdout.write(f"    scope    : {scope_label}\n")
        sys.stdout.write(f"    source   : {cand.source_path}\n")
        sys.stdout.write(f"    type     : {cand.type or 'stdio'}\n")
        if cand.command.argv:
            sys.stdout.write(f"    command  : {' '.join(cand.command.argv)}\n")
        if cand.command.env_keys:
            # NAMES only — never the values.
            sys.stdout.write(
                f"    env keys : {', '.join(cand.command.env_keys)}\n"
            )
        if cand.command.secret_env_keys:
            sys.stdout.write(
                "    secrets  : "
                f"{', '.join(cand.command.secret_env_keys)} (values not shown)\n"
            )
        if cand.classification.placement == "excluded":
            reason = "; ".join(cand.classification.reasons) or "unsupported"
            sys.stdout.write(f"    excluded : {reason}\n")
    sys.stdout.write(
        "\nDry-run only: no MCP profile or agent config was modified.\n"
    )
    return 0


def main(argv: list[str]) -> int:
    if not argv:
        sys.stderr.write("mcp.cli: missing command\n")
        return 2
    command = argv[0]
    rest = argv[1:]

    if command == "import-json":
        scope = _parse_scope(rest)
        if scope is None:
            return 2
        return _emit(import_result(_discover(scope)))
    if command == "import-text":
        scope = _parse_scope(rest)
        if scope is None:
            return 2
        return _render_text(_discover(scope))
    if command == "list-inherited-json":
        scope = _parse_scope(rest)
        if scope is None:
            return 2
        return _emit(inherited_list_result(_discover(scope)))
    if command == "project-keys":
        # Emit known Claude project record keys, one per line. These are
        # directory paths (Claude's own map keys) — not secret. Used by the
        # shell dispatcher to resolve a bare `--project <name>` token.
        for key in ClaudeProvider().project_keys():
            sys.stdout.write(key + "\n")
        return 0

    sys.stderr.write(f"mcp.cli: unknown command {command!r}\n")
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
