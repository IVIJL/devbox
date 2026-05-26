#!/bin/bash
set -euo pipefail

# =============================================================================
# mcp-cli — host-side dispatcher for `devbox mcp <subcommand>` (ADR 0013)
# =============================================================================
# Thin shell front-end for the MCP command group. It parses the subcommand and
# flags, prints human-readable output, and delegates all candidate-model / JSON
# work to the Python core in `scripts/mcp/` (`python3 -m mcp.cli ...`). Keeping
# the dispatcher thin means later slices (02-10) add providers, classification,
# and profile merge in unit-testable Python rather than in shell.
#
# `devbox mcp` is a host-side command like every other devbox command: it must
# run without Docker for `--help`, `import` (empty), `list --inherited`
# (empty), and any `--json` path. Read-only commands in this slice write
# nothing under ~/.config/devbox/mcp/, ~/.claude, or ~/.codex.
#
# This slice (issue 01) is a skeleton:
#   - `--help` lists all planned subcommands;
#   - `import` reports that no import providers are active yet;
#   - `list --inherited` reports an empty inherited result;
#   - `import --json` / `list --inherited --json` emit the versioned, empty
#     candidate envelope from the Python core.
# Everything else (real discovery, profile writes, render, wrapper, install,
# enable/disable/remove) is a later issue and is rejected with a clear
# "not implemented yet" message.
#
# Why this file lives in scripts/ and not lib/: it is a multi-subcommand
# dispatcher invoked via `exec` from docker-run.sh, mirroring
# scripts/agent-browser-broker.sh. lib/ holds reusable sourced modules.
# =============================================================================

DEVBOX_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

# Locate the Python core package (scripts/mcp/). Putting scripts/ on
# PYTHONPATH lets `python3 -m mcp.cli` resolve `import mcp`.
MCP_PY_DIR="$DEVBOX_DIR/scripts"

# --- Usage -------------------------------------------------------------------

_usage() {
    cat <<'EOF'
Usage: devbox mcp <subcommand> [args]

Discover, classify, and manage MCP servers for devbox Containers (ADR 0013).
Devbox stores an agent-neutral MCP profile and renders agent-specific config
for Claude Code and Codex. The first version supports Container MCP servers;
Host MCP servers are detected and explained but not launched.

Subcommands:
  import      Discover Inherited MCP servers from agent config and classify
              them as import candidates (dry-run; no writes).
  list        Show the effective MCP profile (use --inherited for detected
              Inherited MCP servers only).
  render      Re-render devbox-managed entries into Claude Code / Codex config.
  doctor      Diagnose MCP profile / render / runtime problems.
  add         Add a new Devbox MCP server from an explicit command spec.
  install     Materialize an existing profile entry into persistent runtime.
  enable      Resume rendering a previously disabled MCP server.
  disable     Keep a definition but stop rendering it.
  remove      Delete a devbox-managed MCP server definition for one scope.

Read-only commands in this version:
  devbox mcp import [--json]              Dry-run discovery report.
  devbox mcp list --inherited [--json]    Detected Inherited MCP servers.

Common flags:
  --json      Emit machine-readable JSON (valid even when the result is empty).
  -h, --help  Show this help.
EOF
}

# --- Python JSON delegation --------------------------------------------------

# Run the Python core with scripts/ on PYTHONPATH. All JSON serialization of
# the candidate model lives there (single source of truth).
_run_py() {
    PYTHONPATH="$MCP_PY_DIR${PYTHONPATH:+:$PYTHONPATH}" python3 -m mcp.cli "$@"
}

# --- Subcommands -------------------------------------------------------------

cmd_import() {
    local json=false
    local arg
    for arg in "$@"; do
        case "$arg" in
            --json) json=true ;;
            -h|--help) _usage; return 0 ;;
            -*)
                echo "Unknown flag for 'mcp import': $arg" >&2
                return 2
                ;;
            *)
                echo "Unexpected argument for 'mcp import': $arg" >&2
                return 2
                ;;
        esac
    done

    if [ "$json" = true ]; then
        # Versioned envelope with an empty candidates array — no providers yet.
        _run_py import-json
        return 0
    fi

    # Dry-run by default (ADR 0013 / local-plan-mcp.md decision 10). No writes.
    echo "No import providers active yet."
    echo "Inherited MCP server discovery for Claude Code and Codex arrives in a"
    echo "later devbox release. Nothing was scanned and nothing was written."
}

cmd_list() {
    local inherited=false
    local json=false
    local arg
    for arg in "$@"; do
        case "$arg" in
            --inherited) inherited=true ;;
            --json) json=true ;;
            -h|--help) _usage; return 0 ;;
            -*)
                echo "Unknown flag for 'mcp list': $arg" >&2
                return 2
                ;;
            *)
                echo "Unexpected argument for 'mcp list': $arg" >&2
                return 2
                ;;
        esac
    done

    # This skeleton only implements the inherited view. The effective-profile
    # view (default `devbox mcp list`) needs profile state, which is a later
    # issue.
    if [ "$inherited" != true ]; then
        echo "Usage: devbox mcp list --inherited [--json]" >&2
        echo "The effective-profile view of 'devbox mcp list' is not implemented yet." >&2
        return 2
    fi

    if [ "$json" = true ]; then
        # Versioned envelope with an empty inherited array — no providers yet.
        _run_py list-inherited-json
        return 0
    fi

    echo "No Inherited MCP servers detected."
    echo "Provider-based discovery for Claude Code and Codex arrives in a later"
    echo "devbox release. Nothing was scanned and nothing was written."
}

# Placeholder for subcommands that are planned but not part of this slice.
# Listing them in --help sets user expectations; invoking them must fail
# clearly rather than silently no-op.
_not_implemented() {
    local sub="$1"
    echo "'devbox mcp $sub' is planned but not implemented yet." >&2
    echo "Run 'devbox mcp --help' to see the available commands." >&2
    return 2
}

# --- Dispatch ----------------------------------------------------------------

main() {
    local sub="${1:-}"
    case "$sub" in
        ''|-h|--help|help)
            _usage
            exit 0
            ;;
    esac
    shift
    case "$sub" in
        import) cmd_import "$@" ;;
        list)   cmd_list "$@" ;;
        render|doctor|add|install|enable|disable|remove)
            _not_implemented "$sub"
            ;;
        *)
            echo "Unknown mcp subcommand: $sub" >&2
            _usage >&2
            exit 2
            ;;
    esac
}

main "$@"
