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
# This slice (issue 02) adds the first real import provider — read-only Claude
# Code MCP discovery:
#   - `--help` lists all planned subcommands;
#   - `import` scans the current Project record + global Claude config and
#     prints discovered Inherited MCP candidates (dry-run; no writes);
#   - `import --project <name-or-path>` scans one explicit Project;
#   - `import --all` scans every known Claude project record;
#   - `import --json` / `list --inherited --json` emit the versioned candidate
#     envelope from the Python core.
# Everything else (profile writes via --apply, render, wrapper, install,
# enable/disable/remove) is a later issue and is rejected with a clear
# "not implemented yet" message.
#
# Claude keys its project records by ABSOLUTE PATH in ~/.claude/.claude.json.
# The dispatcher resolves the current working directory (default scope) or an
# explicit `--project` token to that record-key form, then passes it to the
# Python core. No secret values ever cross this boundary — the Python core
# only emits env-var names.
#
# Why this file lives in scripts/ and not lib/: it is a multi-subcommand
# dispatcher invoked via `exec` from docker-run.sh, mirroring
# scripts/agent-browser-broker.sh. lib/ holds reusable sourced modules.
# =============================================================================

DEVBOX_DIR="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

# Locate the Python core package (scripts/mcp/). Putting scripts/ on
# PYTHONPATH lets `python3 -m mcp.cli` resolve `import mcp`.
MCP_PY_DIR="$DEVBOX_DIR/scripts"

# Naming helpers (devbox::sanitize) — used to match a bare `--project <name>`
# token against Claude's absolute-path record keys via ADR 0005 sanitized
# basenames. Sourced read-only; defines no globals we mutate here.
# shellcheck source-path=SCRIPTDIR source=../lib/naming.sh disable=SC1091
. "$DEVBOX_DIR/lib/naming.sh"

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
  devbox mcp import [scope] [--json]            Dry-run discovery report.
  devbox mcp list --inherited [scope] [--json]  Detected Inherited MCP servers.

Scope flags (import / list --inherited):
  (default)                 Current Project record + global Claude config.
  --project <name-or-path>  Scan one explicit Project (repeatable).
  --all                     Scan every known Claude project record.

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

# --- Project-key resolution --------------------------------------------------

# Resolve a `--project <name-or-path>` token to the absolute-path record key
# Claude uses in ~/.claude/.claude.json. Prints the resolved key on stdout.
#
# Resolution order:
#   1. A token that looks like a path (contains '/', starts with '.' or '~',
#      or names an existing directory) -> canonical absolute path.
#   2. Otherwise a bare project name -> match against known Claude project
#      record keys by ADR 0005 sanitized basename. A single match wins; zero
#      or multiple matches is an error (the caller must disambiguate by path).
_resolve_project_key() {
    local token="$1"
    local expanded="$token"

    # Expand a leading ~ to $HOME for path-like tokens. The case patterns use a
    # literal tilde to *detect* the prefix; the substitution does the expanding.
    local tilde='~'
    case "$expanded" in
        "$tilde") expanded="$HOME" ;;
        "$tilde"/*) expanded="$HOME/${expanded#"$tilde"/}" ;;
    esac

    # Path-like tokens: a leading dot or slash, an embedded slash, or a token
    # that names an existing directory. Otherwise treat as a bare project name.
    local is_path=false
    case "$token" in
        .*|/*|*/*) is_path=true ;;
    esac
    if [ "$is_path" = true ] || [ -d "$expanded" ]; then
        # Canonicalize. readlink -f works whether or not the path exists, but a
        # real directory gives the most reliable Claude record key.
        local abs
        abs="$(readlink -f "$expanded" 2>/dev/null || true)"
        [ -z "$abs" ] && abs="$expanded"
        printf '%s\n' "$abs"
        return 0
    fi

    # Bare name: match against Claude record keys by sanitized basename.
    local want
    want="$(devbox::sanitize "$token")"
    local matches=()
    local key base
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        base="$(devbox::sanitize "$(basename "$key")")"
        [ "$base" = "$want" ] && matches+=("$key")
    done < <(_run_py project-keys)

    case "${#matches[@]}" in
        1) printf '%s\n' "${matches[0]}"; return 0 ;;
        0)
            echo "No Claude project record matches name '$token'." >&2
            echo "Pass an explicit path, e.g. --project /home/you/Projekty/$token" >&2
            return 1
            ;;
        *)
            echo "Project name '$token' is ambiguous; matched:" >&2
            printf '  %s\n' "${matches[@]}" >&2
            echo "Disambiguate with an explicit path." >&2
            return 1
            ;;
    esac
}

# Resolve the scope flags shared by `import` and `list --inherited` into the
# argument list passed to the Python core. Inputs (as positional args):
#   $1   subcommand label (for error messages, e.g. "mcp import")
#   $2   "true"/"false" — whether --all was given
#   $3.. the collected --project tokens (may be empty)
# Result is written, one element per line, to stdout so the caller can read it
# into an array. Returns non-zero on a scope error (message already on stderr).
_build_scope_args() {
    local label="$1" all="$2"
    shift 2
    local -a tokens=("$@")

    if [ "$all" = true ]; then
        # --all scans every known Claude project record; explicit --project
        # tokens are redundant in that mode, so flag the conflict rather than
        # silently ignore them.
        if [ "${#tokens[@]}" -gt 0 ]; then
            echo "'$label --all' cannot be combined with --project." >&2
            return 1
        fi
        printf '%s\n' "--all"
        return 0
    fi

    if [ "${#tokens[@]}" -gt 0 ]; then
        # Explicit Project(s): resolve each token to a Claude record key.
        local token key
        for token in "${tokens[@]}"; do
            if ! key="$(_resolve_project_key "$token")"; then
                return 1
            fi
            printf '%s\n%s\n' "--project" "$key"
        done
        return 0
    fi

    # Default scope: current working directory's Project + global config.
    local cwd_key
    cwd_key="$(readlink -f "$PWD" 2>/dev/null || printf '%s' "$PWD")"
    printf '%s\n%s\n' "--project" "$cwd_key"
}

# --- Subcommands -------------------------------------------------------------

cmd_import() {
    local json=false
    local all=false
    local -a projects=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --json) json=true ;;
            --all) all=true ;;
            --project)
                shift
                if [ "$#" -eq 0 ]; then
                    echo "'mcp import --project' requires a name or path." >&2
                    return 2
                fi
                projects+=("$1")
                ;;
            --project=*) projects+=("${1#--project=}") ;;
            -h|--help) _usage; return 0 ;;
            -*)
                echo "Unknown flag for 'mcp import': $1" >&2
                return 2
                ;;
            *)
                echo "Unexpected argument for 'mcp import': $1" >&2
                return 2
                ;;
        esac
        shift
    done

    local scope_out
    if ! scope_out="$(_build_scope_args "mcp import" "$all" "${projects[@]+"${projects[@]}"}")"; then
        return 2
    fi
    local -a scope_args=()
    local line
    while IFS= read -r line; do
        [ -n "$line" ] && scope_args+=("$line")
    done <<< "$scope_out"

    if [ "$json" = true ]; then
        _run_py import-json "${scope_args[@]}"
        return $?
    fi

    # Dry-run by default (ADR 0013 / local-plan-mcp.md decision 10). No writes.
    _run_py import-text "${scope_args[@]}"
}

cmd_list() {
    local inherited=false
    local json=false
    local all=false
    local -a projects=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --inherited) inherited=true ;;
            --json) json=true ;;
            --all) all=true ;;
            --project)
                shift
                if [ "$#" -eq 0 ]; then
                    echo "'mcp list --project' requires a name or path." >&2
                    return 2
                fi
                projects+=("$1")
                ;;
            --project=*) projects+=("${1#--project=}") ;;
            -h|--help) _usage; return 0 ;;
            -*)
                echo "Unknown flag for 'mcp list': $1" >&2
                return 2
                ;;
            *)
                echo "Unexpected argument for 'mcp list': $1" >&2
                return 2
                ;;
        esac
        shift
    done

    # This slice only implements the inherited view. The effective-profile
    # view (default `devbox mcp list`) needs profile state, which is a later
    # issue.
    if [ "$inherited" != true ]; then
        echo "Usage: devbox mcp list --inherited [--all|--project <name-or-path>] [--json]" >&2
        echo "The effective-profile view of 'devbox mcp list' is not implemented yet." >&2
        return 2
    fi

    local scope_out
    if ! scope_out="$(_build_scope_args "mcp list" "$all" "${projects[@]+"${projects[@]}"}")"; then
        return 2
    fi
    local -a scope_args=()
    local line
    while IFS= read -r line; do
        [ -n "$line" ] && scope_args+=("$line")
    done <<< "$scope_out"

    if [ "$json" = true ]; then
        _run_py list-inherited-json "${scope_args[@]}"
        return $?
    fi

    # Reuse the import text renderer for the human-readable inherited view —
    # same candidate shape, same scope, no writes.
    _run_py import-text "${scope_args[@]}"
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
