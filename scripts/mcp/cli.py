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
from .apply import ApplyConflictError, apply_selection, is_applicable
from .candidate import Candidate
from .classify import classify_candidate
from .merge import MergedCandidate, merge_candidates
from .providers import ClaudeProvider, CodexProvider
from .render import (
    DEVBOX_PREFIX,
    WRAPPER_COMMAND,
    AgentPlan,
    RenderPlan,
    build_render_plan,
)
from .runner import RunnerError, run as runner_run
from .identity import NotInsideContainerError
from .writer import RenderWriteError, write_plan
from .lifecycle import (
    DoctorReport,
    EffectiveList,
    FixResult,
    LifecycleError,
    RemoveResult,
    ToggleResult,
    apply_doctor_fixes,
    effective_list,
    remove_server,
    run_doctor,
    server_has_secrets,
    set_enabled,
)


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


class _Selection:
    """Parsed apply selection flags layered on top of the scope flags.

    ``--server <name>`` and ``--import-id <id>`` are repeatable and choose which
    discovered candidates to apply. ``--all-applicable`` selects every applicable
    (``container``) candidate — used by the shell dispatcher after an interactive
    multi-select picker has already confirmed the choice with the user.
    """

    def __init__(self) -> None:
        self.scope = _Scope()
        self.servers: list[str] = []
        self.import_ids: list[str] = []
        self.all_applicable: bool = False


def _parse_selection(argv: list[str]) -> Optional[_Selection]:
    sel = _Selection()
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--all":
            sel.scope.all_projects = True
        elif arg == "--no-global":
            sel.scope.include_global = False
        elif arg == "--all-applicable":
            sel.all_applicable = True
        elif arg == "--project":
            i += 1
            if i >= len(argv):
                sys.stderr.write("mcp.cli: --project requires a value\n")
                return None
            sel.scope.project_keys.append(argv[i])
        elif arg == "--server":
            i += 1
            if i >= len(argv):
                sys.stderr.write("mcp.cli: --server requires a value\n")
                return None
            sel.servers.append(argv[i])
        elif arg == "--import-id":
            i += 1
            if i >= len(argv):
                sys.stderr.write("mcp.cli: --import-id requires a value\n")
                return None
            sel.import_ids.append(argv[i])
        else:
            sys.stderr.write(f"mcp.cli: unknown argument {arg!r}\n")
            return None
        i += 1
    return sel


def _resolve_selection(
    merged: list[MergedCandidate], sel: _Selection
) -> Optional[list[MergedCandidate]]:
    """Turn selection flags into the concrete candidates to apply.

    Resolution rules (local-plan-mcp.md decision 18):

      * ``--import-id <id>`` picks an exact candidate; an unknown ID is an error.
      * ``--server <name>`` picks by name but FAILS on ambiguity (two candidates
        share the name, e.g. a conflict or a global+project pair) and tells the
        user to disambiguate with ``--import-id``.
      * ``--all-applicable`` picks every applicable candidate (post-picker path).
      * No selection at all is an error here — the shell dispatcher only calls
        the Python apply path once it has a selection (picker or flags), and a
        non-interactive apply without selection is rejected upstream.

    Returns None (after writing a message to stderr) on any selection error.
    """
    chosen: dict[str, MergedCandidate] = {}

    by_id = {m.import_id: m for m in merged}
    for iid in sel.import_ids:
        m = by_id.get(iid)
        if m is None:
            sys.stderr.write(f"mcp.cli: no candidate with import id {iid!r}\n")
            return None
        chosen[m.import_id] = m

    for name in sel.servers:
        matches = [m for m in merged if m.candidate.name == name]
        if not matches:
            sys.stderr.write(f"mcp.cli: no candidate named {name!r}\n")
            return None
        if len(matches) > 1:
            ids = ", ".join(m.import_id for m in matches)
            sys.stderr.write(
                f"mcp.cli: server name {name!r} is ambiguous "
                f"({len(matches)} candidates); choose one with --import-id "
                f"({ids})\n"
            )
            return None
        chosen[matches[0].import_id] = matches[0]

    if sel.all_applicable:
        for m in merged:
            if is_applicable(m):
                chosen[m.import_id] = m

    if not chosen:
        sys.stderr.write(
            "mcp.cli: no candidates selected; pass --server <name>, "
            "--import-id <id>, or --all-applicable\n"
        )
        return None

    # Preserve discovery order for a stable, repeatable summary.
    return [m for m in merged if m.import_id in chosen]


def _apply_payload(merged: list[MergedCandidate], sel: _Selection) -> dict:
    selected = _resolve_selection(merged, sel)
    if selected is None:
        return {"error": "selection"}
    try:
        result = apply_selection(selected)
    except ApplyConflictError as exc:
        sys.stderr.write(f"mcp.cli: {exc}\n")
        return {"error": "conflict"}
    return result.to_dict()


def _render_apply_text(merged: list[MergedCandidate], sel: _Selection) -> int:
    """Human-readable apply summary. SECRET-FREE: copied secret KEY NAMES only.

    Reports each applied server, its scope and profile path, and exactly which
    env keys were copied into the devbox secret store — never their values. Any
    non-applicable selection (host-only / unknown / excluded) is listed as
    skipped with a reason so the user is never left wondering why a choice did
    nothing.
    """
    selected = _resolve_selection(merged, sel)
    if selected is None:
        return 2
    try:
        result = apply_selection(selected)
    except ApplyConflictError as exc:
        sys.stderr.write(f"mcp.cli: {exc}\n")
        return 2

    if not result.applied and not result.skipped:
        sys.stdout.write("No candidates applied.\n")
        return 0

    for a in result.applied:
        scope_label = a.scope
        if a.project_key:
            scope_label = f"{a.scope} ({a.project_key})"
        sys.stdout.write(f"Applied {a.name}\n")
        sys.stdout.write(f"  import id: {a.import_id}\n")
        sys.stdout.write(f"  scope    : {scope_label}\n")
        sys.stdout.write(f"  profile  : {a.profile_path}\n")
        if a.copied_secret_keys:
            sys.stdout.write(
                "  secrets  : copied "
                f"{', '.join(a.copied_secret_keys)} to {a.secrets_path} "
                "(values not shown)\n"
            )
        else:
            sys.stdout.write("  secrets  : none copied\n")

    for s in result.skipped:
        sys.stdout.write(
            f"Skipped {s['name']} ({s['importId']}): {s['reason']}\n"
        )

    # NOTE: agent config is NOT written here. The shell front-end runs
    # auto-render right after a successful apply (unless --no-render), and that
    # step prints exactly what it wrote (or that it was skipped). So this summary
    # must not claim "nothing was modified" — that would be false on the default
    # path; it only states the profile result and points at the render step.
    sys.stdout.write(
        "\nProfile updated. Agent config (Claude Code / Codex) is written by the "
        "render step that follows (use --no-render to skip it).\n"
    )
    return 0


def _render_applicable_list(merged: list[MergedCandidate]) -> int:
    """Emit one applicable candidate per line for the shell's TTY picker.

    Format: ``<import_id>\\t<name>\\t<scope>``. Applicable means ``container``
    placement (the only thing v1 can apply). SECRET-FREE — identity metadata
    only. Non-applicable candidates are intentionally omitted so the picker can
    never offer a host-only/unknown choice.
    """
    for m in merged:
        if not is_applicable(m):
            continue
        scope = m.candidate.source_scope
        if m.candidate.source_project:
            scope = f"{scope}:{m.candidate.source_project}"
        sys.stdout.write(f"{m.import_id}\t{m.candidate.name}\t{scope}\n")
    return 0


def _render_agent_text(plan: AgentPlan) -> None:
    """Human-readable render preview for one agent (SECRET-FREE).

    Shows the planned devbox-managed entries (their prefixed name and the WRAPPER
    command they call — never the raw MCP command, never a secret value), and
    separates existing agent entries by ownership so the re-render contract is
    visible: devbox would replace only its own ``devbox-`` entries and leave
    inherited/manual entries untouched.
    """
    sys.stdout.write(f"\n{plan.agent} ({plan.config_path})\n")
    if not plan.supported:
        sys.stdout.write(f"  unsupported: {plan.unsupported_reason}\n")
        return

    if plan.planned:
        sys.stdout.write("  planned devbox-managed entries:\n")
        for entry in plan.planned:
            scope_label = entry.scope
            if entry.project_key:
                scope_label = f"{entry.scope} ({entry.project_key})"
            sys.stdout.write(f"    {entry.rendered_name}\n")
            sys.stdout.write(f"      scope  : {scope_label}\n")
            # The WRAPPER call, not the raw MCP command.
            sys.stdout.write(f"      command: {' '.join(entry.argv)}\n")
            if entry.env_keys:
                # NAMES only — never values.
                sys.stdout.write(f"      env    : {', '.join(entry.env_keys)}\n")
            if entry.secret_env_keys:
                sys.stdout.write(
                    "      secrets: "
                    f"{', '.join(entry.secret_env_keys)} (values not shown)\n"
                )
    else:
        sys.stdout.write("  planned devbox-managed entries: none\n")

    if plan.managed_existing:
        sys.stdout.write(
            "  existing devbox-managed (would be replaced on render): "
            f"{', '.join(plan.managed_existing)}\n"
        )
    if plan.inherited_existing:
        sys.stdout.write(
            "  inherited/manual entries (never modified): "
            f"{', '.join(plan.inherited_existing)}\n"
        )


def _render_plan_text(plan: RenderPlan) -> int:
    """Human-readable dry-run render report across Claude Code and Codex.

    SECRET-FREE: only env-variable NAMES and the wrapper command ever appear.
    """
    # Even with no enabled profile servers, a re-render still has work to do if
    # the agent config carries stale devbox-managed entries: it would REMOVE
    # them. Hiding that behind an early "nothing to render" message would make
    # stale-entry cleanup invisible, so only short-circuit when there is also
    # nothing managed to clean up in either agent.
    has_stale_managed = bool(
        plan.claude.managed_existing or plan.codex.managed_existing
    )
    # An UNSUPPORTED agent (e.g. Codex with no TOML parser) is itself reportable
    # status: short-circuiting would hide that devbox could not even inspect that
    # agent's config for stale entries. Only print the empty short-circuit when
    # every agent is supported AND there is nothing to render or clean up.
    any_unsupported = not plan.claude.supported or not plan.codex.supported
    renderable = plan.renderable_servers
    skipped = plan.skipped
    if (
        not renderable
        and not has_stale_managed
        and not any_unsupported
        and not skipped
    ):
        sys.stdout.write(
            "No enabled MCP profile servers to render, and no devbox-managed "
            "entries to clean up. Import or add servers first "
            "(see 'devbox mcp import').\n"
        )
        return 0

    if renderable:
        sys.stdout.write(
            f"Render preview for {len(renderable)} enabled MCP profile "
            "server(s).\n"
        )
    else:
        sys.stdout.write(
            "No enabled MCP profile servers; a re-render would REMOVE the "
            "stale devbox-managed entries shown below.\n"
        )
    sys.stdout.write(
        f"Rendered names are '{DEVBOX_PREFIX}' prefixed and call the wrapper "
        f"'{WRAPPER_COMMAND} <server>'.\n"
    )

    _render_agent_text(plan.claude)
    _render_agent_text(plan.codex)
    _render_skipped_text(skipped)

    sys.stdout.write(
        "\nDry-run only: no Claude Code or Codex config was modified.\n"
        "Re-render replaces only devbox-managed (devbox-) entries; "
        "inherited/manual entries are never touched.\n"
    )
    return 0


def _render_skipped_text(skipped: list) -> None:
    """Report profile servers that could not be rendered, and why (SECRET-FREE).

    Surfaces the actionable reason (e.g. a legacy project profile with no
    recorded key) so a 'render reported success but my server never launched'
    surprise becomes a visible, fixable line instead.
    """
    if not skipped:
        return
    sys.stdout.write(
        f"\nSkipped {len(skipped)} server(s) (not rendered):\n"
    )
    for srv in skipped:
        where = f" [project {srv.project_key}]" if srv.project_key else ""
        sys.stdout.write(f"  - {srv.name}{where}: {srv.skip_reason}\n")


def _render_written_text(plan: RenderPlan, written: list[str]) -> int:
    """Human-readable summary after a REAL render (SECRET-FREE).

    Reports which agents were written and the planned devbox-managed entries
    per agent. An unsupported agent (e.g. Codex with no TOML parser) is reported
    as skipped rather than written, so the user sees exactly what changed.
    """
    renderable = plan.renderable_servers
    if renderable:
        sys.stdout.write(
            f"Rendered {len(renderable)} enabled MCP profile server(s) "
            f"into: {', '.join(written) if written else 'no agents'}.\n"
        )
    else:
        sys.stdout.write(
            "No enabled MCP profile servers; removed any stale devbox-managed "
            f"entries from: {', '.join(written) if written else 'no agents'}.\n"
        )
    sys.stdout.write(
        f"Rendered names are '{DEVBOX_PREFIX}' prefixed and call the wrapper "
        f"'{WRAPPER_COMMAND} <server>'.\n"
    )

    _render_agent_text(plan.claude)
    # Only describe Codex if it was actually written; an unsupported Codex was
    # skipped (not an error) and its reason is still worth showing.
    if plan.codex.supported:
        _render_agent_text(plan.codex)
    else:
        sys.stdout.write(f"\n{plan.codex.agent} ({plan.codex.config_path})\n")
        sys.stdout.write(
            f"  skipped: {plan.codex.unsupported_reason}\n"
        )

    _render_skipped_text(plan.skipped)

    sys.stdout.write(
        "\nWrote only devbox-managed (devbox-) entries; inherited/manual "
        "entries were left unchanged.\n"
    )
    return 0


def _render_effective_table(result: EffectiveList) -> int:
    """Readable effective MCP profile table (issue 08 `devbox mcp list`).

    Columns: NAME, SCOPE, STATUS, PLACEMENT, RUNTIME, SOURCE (decision 22). A
    Project entry shadowing a same-named global entry is marked on the global
    row. SECRET-FREE: every column is non-secret identity; env values never
    appear. PLACEMENT is ``container`` for every devbox profile entry (v1 only
    stores Container MCP servers).
    """
    if not result.entries:
        sys.stdout.write(
            "No devbox MCP profile servers. Import inherited servers with "
            "'devbox mcp import --apply' first.\n"
        )
        return 0

    rows: list[tuple[str, str, str, str, str, str]] = []
    for e in result.entries:
        scope_label = e.scope
        if e.project_key:
            scope_label = f"{e.scope}:{e.project_key.rsplit('/', 1)[-1]}"
        status = e.status
        if e.shadowed:
            status = f"{status} (shadowed)"
        source = e.source_provider or "-"
        rows.append(
            (
                e.name,
                scope_label,
                status,
                "container",
                e.runtime,
                source,
            )
        )

    headers = ("NAME", "SCOPE", "STATUS", "PLACEMENT", "RUNTIME", "SOURCE")
    widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(cell))

    def _fmt(cells: tuple[str, ...]) -> str:
        return "  ".join(
            cell.ljust(widths[i]) for i, cell in enumerate(cells)
        ).rstrip()

    sys.stdout.write(_fmt(headers) + "\n")
    for row in rows:
        sys.stdout.write(_fmt(row) + "\n")
    if any(e.shadowed for e in result.entries):
        sys.stdout.write(
            "\nA (shadowed) global entry is overridden by a Project entry of the "
            "same name for the current Project.\n"
        )
    return 0


def _render_toggle_text(result: ToggleResult, enabled: bool) -> int:
    """Human-readable enable/disable summary (SECRET-FREE)."""
    verb = "enabled" if enabled else "disabled"
    scope_label = result.scope
    if result.project_key:
        scope_label = f"{result.scope} ({result.project_key})"
    if result.no_op:
        sys.stdout.write(
            f"MCP server {result.name!r} is already {verb} in the {scope_label} "
            "profile; no change.\n"
        )
        return 0
    if result.created_override:
        sys.stdout.write(
            f"Disabled MCP server {result.name!r} for the {scope_label} profile "
            "via a Project override; the global entry is unchanged and still "
            "available in other projects.\n"
        )
        # Codex has no per-project MCP namespace, so a project-only disable of a
        # globally-rendered server cannot be enforced for Codex (it stays offered
        # in the single global Codex table). Claude enforces it via the project
        # record shadow. Be honest about the Codex limitation rather than imply a
        # complete disable.
        sys.stdout.write(
            "  note: this Project disable is enforced for Claude Code only; "
            "Codex has no per-project MCP scope, so the server remains offered "
            "in Codex. Use 'devbox mcp disable {name} --global' to disable it "
            "everywhere.\n".format(name=result.name)
        )
    else:
        sys.stdout.write(
            f"{verb.capitalize()} MCP server {result.name!r} in the "
            f"{scope_label} profile.\n"
        )
    return 0


def _render_remove_text(result: RemoveResult) -> int:
    """Human-readable remove summary (SECRET-FREE)."""
    scope_label = result.scope
    if result.project_key:
        scope_label = f"{result.scope} ({result.project_key})"
    if result.removed:
        sys.stdout.write(
            f"Removed devbox MCP server {result.name!r} from the {scope_label} "
            "profile.\n"
        )
    else:
        # The profile entry was already gone; this run only cleaned up an
        # orphaned scoped secret block.
        sys.stdout.write(
            f"No {scope_label} profile entry for {result.name!r} (already "
            "removed); cleaned up its orphaned secrets.\n"
        )
    if result.secrets_purged:
        if result.purged_secret_keys:
            sys.stdout.write(
                "Purged scoped secret store keys: "
                f"{', '.join(result.purged_secret_keys)} (values not shown).\n"
            )
        else:
            sys.stdout.write("No scoped secrets to purge.\n")
    else:
        sys.stdout.write(
            "Left any scoped secrets in place (pass --purge to delete them).\n"
        )
    sys.stdout.write(
        "Inherited/manual agent MCP entries were not touched.\n"
    )
    return 0


_SEVERITY_TAG = {"error": "ERROR", "warning": "WARN ", "info": "INFO "}


def _render_doctor_text(report: DoctorReport) -> int:
    """Human-readable doctor report (SECRET-FREE).

    Lists each finding with its severity, message, and a concrete repair
    command. Exit code is 1 when any ERROR finding is present, else 0.
    """
    where = "inside a devbox Container" if report.inside_container else "on the host"
    sys.stdout.write(f"devbox mcp doctor ({where}):\n")
    if not report.findings:
        sys.stdout.write("  All checks passed. No problems detected.\n")
        return 0
    for f in report.findings:
        tag = _SEVERITY_TAG.get(f.severity, f.severity.upper())
        sys.stdout.write(f"  [{tag}] {f.message}\n")
        if f.repair:
            sys.stdout.write(f"          repair: {f.repair}\n")
    fixable = [f for f in report.findings if f.fixable]
    if fixable:
        sys.stdout.write(
            "\nSome problems can be fixed safely with 'devbox mcp doctor --fix'.\n"
        )
    return 0 if report.ok else 1


def _render_fix_text(result: FixResult) -> int:
    """Human-readable doctor --fix summary (SECRET-FREE)."""
    if result.actions:
        sys.stdout.write("Applied safe fixes:\n")
        for action in result.actions:
            sys.stdout.write(f"  - {action}\n")
    else:
        sys.stdout.write("No safe fixes were needed.\n")
    if result.remaining:
        sys.stdout.write("\nRemaining problems (not safely auto-fixable):\n")
        for f in result.remaining:
            tag = _SEVERITY_TAG.get(f.severity, f.severity.upper())
            sys.stdout.write(f"  [{tag}] {f.message}\n")
            if f.repair:
                sys.stdout.write(f"          repair: {f.repair}\n")
    has_error = any(f.severity == "error" for f in result.remaining)
    return 1 if has_error else 0


class _LifecycleScope:
    """Scope flags for the lifecycle commands: optional --project, --global."""

    def __init__(self) -> None:
        self.project_key: Optional[str] = None
        self.is_global: bool = False
        self.purge: bool = False
        self.positional: list[str] = []


def _parse_lifecycle_scope(argv: list[str]) -> Optional[_LifecycleScope]:
    """Parse enable/disable/remove flags. Returns None on a parse error."""
    out = _LifecycleScope()
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--global":
            out.is_global = True
        elif arg == "--purge":
            out.purge = True
        elif arg == "--project":
            i += 1
            if i >= len(argv):
                sys.stderr.write("mcp.cli: --project requires a value\n")
                return None
            out.project_key = argv[i]
        elif arg.startswith("--project="):
            value = arg[len("--project="):]
            if not value:
                sys.stderr.write("mcp.cli: --project requires a non-empty value\n")
                return None
            out.project_key = value
        elif arg.startswith("-"):
            sys.stderr.write(f"mcp.cli: unknown argument {arg!r}\n")
            return None
        else:
            out.positional.append(arg)
        i += 1
    return out


def _resolve_lifecycle_scope(
    scope: _LifecycleScope,
) -> Optional[tuple[str, Optional[str]]]:
    """Map the parsed flags to (scope, project_key), or None on conflict.

    ``--global`` selects global scope; a ``--project <key>`` selects project
    scope keyed by that FULL project key (the shell dispatcher resolves the
    token to a Claude record key before invoking). They are mutually exclusive.
    With neither, default to global scope (a bare 'enable foo' targets the
    global profile, matching how a global import lands).
    """
    if scope.is_global and scope.project_key:
        sys.stderr.write(
            "mcp.cli: --global and --project are mutually exclusive\n"
        )
        return None
    if scope.project_key:
        return ("project", scope.project_key)
    return ("global", None)


def _cmd_list(argv: list[str], as_json: bool) -> int:
    """`devbox mcp list` effective view. Scope flags reuse the shared parser."""
    scope = _parse_scope(argv)
    if scope is None:
        return 2
    try:
        result = effective_list(
            project_keys=scope.project_keys or None,
            all_projects=scope.all_projects,
        )
    except LifecycleError as exc:
        sys.stderr.write(f"mcp.cli: {exc}\n")
        return 1
    if as_json:
        return _emit(result.to_dict())
    return _render_effective_table(result)


def _cmd_toggle(argv: list[str], enabled: bool, as_json: bool) -> int:
    """`devbox mcp enable|disable <name>` profile-state toggle."""
    scope = _parse_lifecycle_scope(argv)
    if scope is None:
        return 2
    if len(scope.positional) != 1:
        sys.stderr.write(
            "mcp.cli: enable/disable take exactly one server name\n"
        )
        return 2
    resolved = _resolve_lifecycle_scope(scope)
    if resolved is None:
        return 2
    scope_name, project_key = resolved
    name = scope.positional[0]
    try:
        result = set_enabled(name, scope_name, project_key, enabled)
    except LifecycleError as exc:
        sys.stderr.write(f"mcp.cli: {exc}\n")
        return 1
    if as_json:
        return _emit(result.to_dict())
    return _render_toggle_text(result, enabled)


def _cmd_remove(argv: list[str], as_json: bool) -> int:
    """`devbox mcp remove <name>` profile-entry removal (purge opt-in)."""
    scope = _parse_lifecycle_scope(argv)
    if scope is None:
        return 2
    if len(scope.positional) != 1:
        sys.stderr.write("mcp.cli: remove takes exactly one server name\n")
        return 2
    resolved = _resolve_lifecycle_scope(scope)
    if resolved is None:
        return 2
    scope_name, project_key = resolved
    name = scope.positional[0]
    try:
        result = remove_server(name, scope_name, project_key, purge=scope.purge)
    except LifecycleError as exc:
        sys.stderr.write(f"mcp.cli: {exc}\n")
        return 1
    if as_json:
        return _emit(result.to_dict())
    return _render_remove_text(result)


def _cmd_remove_secret_check(argv: list[str]) -> int:
    """Report whether a remove target has scoped secrets (one key NAME per line).

    Used by the shell dispatcher to decide whether to prompt for confirmation
    before a non-purge remove would orphan a secret block. SECRET-FREE: prints
    key NAMES only, never values. Output is empty when there are no secrets.
    """
    scope = _parse_lifecycle_scope(argv)
    if scope is None:
        return 2
    if len(scope.positional) != 1:
        sys.stderr.write("mcp.cli: remove-secret-check takes one server name\n")
        return 2
    resolved = _resolve_lifecycle_scope(scope)
    if resolved is None:
        return 2
    scope_name, project_key = resolved
    for key in server_has_secrets(scope.positional[0], scope_name, project_key):
        sys.stdout.write(key + "\n")
    return 0


def _cmd_doctor(argv: list[str], as_json: bool) -> int:
    """`devbox mcp doctor [--fix]` diagnostics."""
    do_fix = False
    rest: list[str] = []
    for arg in argv:
        if arg == "--fix":
            do_fix = True
        else:
            rest.append(arg)
    if rest:
        sys.stderr.write(
            f"mcp.cli: unexpected argument(s) for doctor: {' '.join(rest)}\n"
        )
        return 2
    report = run_doctor()
    if do_fix:
        fix = apply_doctor_fixes(report)
        if as_json:
            _emit(fix.to_dict())
            return 1 if any(f.severity == "error" for f in fix.remaining) else 0
        return _render_fix_text(fix)
    if as_json:
        _emit(report.to_dict())
        return 0 if report.ok else 1
    return _render_doctor_text(report)


def _run_wrapper(argv: list[str]) -> int:
    """Parse the wrapper args and launch the named server (never returns on OK).

    Accepts ``[--project <full-project-key>] <server>``; the ``--project`` form
    matches what the render path emits for a Project-scoped entry. Container
    identity, resolution, env validation, and exec live in ``mcp.runner``;
    failures map to clear, SECRET-FREE stderr messages and a non-zero exit.
    """
    project_key: Optional[str] = None
    server: Optional[str] = None
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--project":
            i += 1
            if i >= len(argv):
                sys.stderr.write("devbox-mcp-run: --project requires a value\n")
                return 2
            project_key = argv[i]
        elif arg.startswith("--project="):
            project_key = arg[len("--project="):]
        elif arg.startswith("-"):
            sys.stderr.write(f"devbox-mcp-run: unknown flag {arg!r}\n")
            return 2
        elif server is None:
            server = arg
        else:
            sys.stderr.write(
                f"devbox-mcp-run: unexpected extra argument {arg!r}\n"
            )
            return 2
        i += 1

    if not server:
        sys.stderr.write(
            "devbox-mcp-run: missing server name\n"
            "Usage: devbox-mcp-run [--project <project-key>] <server>\n"
        )
        return 2

    try:
        return runner_run(server, project_key)
    except NotInsideContainerError as exc:
        sys.stderr.write(f"devbox-mcp-run: {exc}\n")
        return 3
    except RunnerError as exc:
        sys.stderr.write(f"devbox-mcp-run: {exc}\n")
        return 1


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
    if command == "apply-json":
        sel = _parse_selection(rest)
        if sel is None:
            return 2
        merged = _discover(sel.scope)
        payload = _apply_payload(merged, sel)
        if payload.get("error") in ("selection", "conflict"):
            return 2
        return _emit(payload)
    if command == "apply-text":
        sel = _parse_selection(rest)
        if sel is None:
            return 2
        merged = _discover(sel.scope)
        return _render_apply_text(merged, sel)
    if command == "list-applicable":
        scope = _parse_scope(rest)
        if scope is None:
            return 2
        return _render_applicable_list(_discover(scope))
    if command in ("render-json", "render-text"):
        # Render preview reuses the scope flags only to scope WHICH project
        # profiles to read. ``--project`` selects explicit project keys; with no
        # project flags, every project profile is previewed (the full
        # devbox-managed render surface). ``--all`` / ``--no-global`` are not
        # meaningful for a profile-driven preview and are rejected.
        scope = _parse_scope(rest)
        if scope is None:
            return 2
        if scope.all_projects or not scope.include_global:
            sys.stderr.write(
                "mcp.cli: render preview does not accept --all or --no-global\n"
            )
            return 2
        plan = build_render_plan(scope.project_keys or None)
        if command == "render-json":
            return _emit(plan.to_dict())
        return _render_plan_text(plan)
    if command in ("render-write-json", "render-write-text"):
        # REAL render (no --dry-run): write devbox-managed entries into the
        # Claude Code and Codex config trees.
        #
        # Unlike the dry-run PREVIEW (which may scope to one --project just to
        # focus its output), the WRITE path must ALWAYS render the FULL managed
        # surface (global + every project profile). The writers own all
        # ``devbox-`` entries: they strip every existing one and write back only
        # the planned set. A scoped write would therefore delete other projects'
        # already-rendered devbox entries. So --project is rejected here and the
        # plan is always built for the full surface.
        scope = _parse_scope(rest)
        if scope is None:
            return 2
        if scope.all_projects or not scope.include_global:
            sys.stderr.write(
                "mcp.cli: render does not accept --all or --no-global\n"
            )
            return 2
        if scope.project_keys:
            sys.stderr.write(
                "mcp.cli: 'devbox mcp render' writes the full devbox-managed "
                "surface and does not accept --project (a scoped write would "
                "drop other projects' rendered entries). Use "
                "'devbox mcp render --dry-run --project <p>' to preview one "
                "project.\n"
            )
            return 2
        plan = build_render_plan(None)
        try:
            written = write_plan(plan.claude, plan.codex)
        except RenderWriteError as exc:
            sys.stderr.write(f"mcp.cli: {exc}\n")
            return 1
        if command == "render-write-json":
            payload = plan.to_dict()
            payload["dryRun"] = False
            payload["written"] = written
            return _emit(payload)
        return _render_written_text(plan, written)
    if command == "list-json":
        return _cmd_list(rest, as_json=True)
    if command == "list-text":
        return _cmd_list(rest, as_json=False)
    if command == "enable-json":
        return _cmd_toggle(rest, enabled=True, as_json=True)
    if command == "enable-text":
        return _cmd_toggle(rest, enabled=True, as_json=False)
    if command == "disable-json":
        return _cmd_toggle(rest, enabled=False, as_json=True)
    if command == "disable-text":
        return _cmd_toggle(rest, enabled=False, as_json=False)
    if command == "remove-json":
        return _cmd_remove(rest, as_json=True)
    if command == "remove-text":
        return _cmd_remove(rest, as_json=False)
    if command == "remove-secret-check":
        return _cmd_remove_secret_check(rest)
    if command == "doctor-json":
        return _cmd_doctor(rest, as_json=True)
    if command == "doctor-text":
        return _cmd_doctor(rest, as_json=False)
    if command == "run":
        # The devbox-mcp-run wrapper core. Args: [--project <key>] <server>.
        return _run_wrapper(rest)
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
