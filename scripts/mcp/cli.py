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
from .classify import classify_candidate
from .merge import MergedCandidate, merge_candidates
from .providers import ClaudeProvider, CodexProvider


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


def _discover(scope: _Scope) -> list[MergedCandidate]:
    """Collect candidates from ALL import providers and merge them.

    Each provider normalizes its own config into `Candidate`s; the shared
    `merge_candidates` step (issue 03) then collapses identical candidates
    discovered by multiple providers into one result, flags same-name/same-scope
    spec disagreements as conflicts, and assigns every result a stable, secret-
    free ``importId``. The Codex provider is conservative — it contributes
    nothing (cleanly) when no supported Codex MCP config exists.
    """
    raw: list[Candidate] = []
    raw.extend(
        ClaudeProvider().discover(
            project_keys=scope.project_keys,
            include_global=scope.include_global,
            all_projects=scope.all_projects,
        )
    )
    raw.extend(
        CodexProvider().discover(
            project_keys=scope.project_keys,
            include_global=scope.include_global,
            all_projects=scope.all_projects,
        )
    )
    # Evidence-based classification (issue 04). Providers leave non-excluded
    # candidates as ``unknown``; the classifier assigns the real placement /
    # confidence / reasons here, before merge, so the identity-merge step and
    # both output paths (text + JSON) all see the classified result.
    for cand in raw:
        classify_candidate(cand)
    return merge_candidates(raw)


def _render_text(merged: list[MergedCandidate]) -> int:
    """Human-readable discovery report (no secret values, names only).

    Each line group covers one merged candidate: its stable ``importId``, every
    contributing provider/source, the (redacted) command shape and env key
    NAMES, and — when present — a conflict marker pointing at the colliding
    import IDs so the user can pick one with ``--import-id`` once apply exists.
    """
    if not merged:
        sys.stdout.write("No Inherited MCP servers detected in the selected scope.\n")
        return 0

    # v1 supports Container MCP servers only (ADR 0013). After classification,
    # only ``container`` candidates are actually importable; ``host-only`` and
    # ``unknown`` are detected and shown for visibility but are NOT importable
    # in v1, and ``excluded`` (remote/hosted connectors) cannot be imported at
    # all. The summary must reflect that split rather than calling every
    # non-excluded candidate importable.
    def _placement(m: MergedCandidate) -> str:
        return m.candidate.classification.placement

    container = [m for m in merged if _placement(m) == "container"]
    host_only = [m for m in merged if _placement(m) == "host-only"]
    unknown = [m for m in merged if _placement(m) == "unknown"]
    excluded = [m for m in merged if _placement(m) == "excluded"]
    conflicts = [m for m in merged if m.conflict]

    summary = (
        f"Discovered {len(merged)} Inherited MCP server(s) "
        f"({len(container)} importable (container)"
    )
    if host_only:
        summary += f", {len(host_only)} host-only"
    if unknown:
        summary += f", {len(unknown)} unknown"
    if excluded:
        summary += f", {len(excluded)} excluded"
    if conflicts:
        summary += f", {len(conflicts)} in conflict"
    summary += "):\n"
    sys.stdout.write(summary)

    for m in merged:
        cand = m.candidate
        scope_label = cand.source_scope
        if cand.source_project:
            scope_label = f"{scope_label} ({cand.source_project})"
        sys.stdout.write("\n")
        sys.stdout.write(f"  {cand.name}\n")
        sys.stdout.write(f"    import id: {m.import_id}\n")
        sys.stdout.write(f"    providers: {', '.join(m.providers)}\n")
        sys.stdout.write(f"    scope    : {scope_label}\n")
        for src in m.sources:
            sys.stdout.write(f"    source   : {src.provider} -> {src.source_path}\n")
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
        if m.conflict:
            sys.stdout.write(
                "    conflict : same name+scope as a different spec; "
                f"choose by import id ({', '.join(m.conflict_with)})\n"
            )
        # Classification (issue 04): placement + confidence for every candidate,
        # plus the evidence reasons that justify it. Secret-safe — reasons only
        # ever name env keys, never their values.
        cls = cand.classification
        confidence = f"/{cls.confidence}" if cls.confidence else ""
        sys.stdout.write(f"    placement: {cls.placement}{confidence}\n")
        for reason in cls.reasons:
            sys.stdout.write(f"    reason   : {reason}\n")
    sys.stdout.write(
        "\nDry-run only: no MCP profile or agent config was modified.\n"
    )
    return 0


def _runtime_label(cand: Candidate) -> str:
    """Coarse runtime family for the inherited table's RUNTIME column.

    Derived from argv[0] only (the launcher), never from secret-bearing args.
    """
    if not cand.command.argv:
        return "-"
    base = cand.command.argv[0].rsplit("/", 1)[-1].lower()
    node = {"npx", "npm", "pnpm", "yarn", "bunx", "node"}
    python = {"uvx", "uv", "python", "python3", "pipx"}
    docker = {"docker", "podman"}
    if base in node:
        return "node"
    if base in python:
        return "python"
    if base in docker:
        return "docker"
    return base or "-"


def _render_inherited_table(merged: list[MergedCandidate]) -> int:
    """Readable table of Inherited MCP candidates (issue 04 list --inherited).

    Columns: NAME, PROVIDER, SCOPE, STATUS (placement/confidence, plus a
    ``(conflict)`` marker when the merge step flagged competing specs in the
    same name+scope slot), RUNTIME, SOURCE (plan question 22). The PROVIDER and
    SOURCE columns preserve the full merged provenance: every contributing
    provider and every config path are shown, not just the first, so a server
    discovered by both Claude Code and Codex is not silently reduced to one.

    Secret-safe: every column is derived from non-secret identity metadata —
    env-variable values never appear; SOURCE shows the config file path(s) the
    candidate was discovered in.
    """
    if not merged:
        sys.stdout.write(
            "No Inherited MCP servers detected in the selected scope.\n"
        )
        return 0

    any_conflict = any(m.conflict for m in merged)

    rows: list[tuple[str, str, str, str, str, str]] = []
    for m in merged:
        cand = m.candidate
        scope_label = cand.source_scope
        if cand.source_project:
            scope_label = f"{scope_label}:{cand.source_project.rsplit('/', 1)[-1]}"
        cls = cand.classification
        status = cls.placement
        if cls.confidence:
            status = f"{cls.placement}/{cls.confidence}"
        # A conflict means another candidate shares this name+scope with a
        # different spec; the user must choose between import IDs (issue 05).
        # The import text and JSON views already expose this — keep the table
        # honest about it too rather than showing two identical-looking rows.
        if m.conflict:
            status = f"{status} (conflict)"
        # Preserve all merged sources, not just the first: a server discovered
        # by multiple providers carries one source per provider/path.
        sources = (
            "; ".join(f"{s.provider}:{s.source_path}" for s in m.sources)
            or cand.source_path
        )
        rows.append(
            (
                cand.name,
                ", ".join(m.providers),
                scope_label,
                status,
                _runtime_label(cand),
                sources,
            )
        )

    headers = ("NAME", "PROVIDER", "SCOPE", "STATUS", "RUNTIME", "SOURCE")
    widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(cell))

    def _fmt(cells: tuple[str, ...]) -> str:
        return "  ".join(cell.ljust(widths[i]) for i, cell in enumerate(cells)).rstrip()

    sys.stdout.write(_fmt(headers) + "\n")
    for row in rows:
        sys.stdout.write(_fmt(row) + "\n")
    if any_conflict:
        sys.stdout.write(
            "\nA (conflict) row shares its name+scope with a different spec; "
            "use the import view's import IDs to choose between them.\n"
        )
    sys.stdout.write(
        "\nInherited MCP servers only (read-only); no profile was written.\n"
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
    if command == "list-inherited-text":
        scope = _parse_scope(rest)
        if scope is None:
            return 2
        return _render_inherited_table(_discover(scope))
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
