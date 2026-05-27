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
  render      Preview (--dry-run) or re-render devbox-managed entries into
              Claude Code / Codex config. This version supports --dry-run only.
  doctor      Diagnose MCP profile / render / runtime problems.
  add         Add a new Devbox MCP server from an explicit command spec.
  install     Materialize an existing profile entry into persistent runtime.
  enable      Resume rendering a previously disabled MCP server.
  disable     Keep a definition but stop rendering it.
  remove      Delete a devbox-managed MCP server definition for one scope.

Read-only commands in this version:
  devbox mcp import [scope] [--json]            Dry-run discovery report.
  devbox mcp list --inherited [scope] [--json]  Detected Inherited MCP servers.
  devbox mcp render --dry-run [--project <p>] [--json]
      Preview the Claude Code / Codex config devbox would render from the
      profile. Rendered names are 'devbox-' prefixed and call the wrapper
      'devbox-mcp-run <server>' (never the raw command, never secret values).
      Re-render would replace only devbox-managed entries; inherited/manual
      agent MCP entries are never modified. Codex is previewed against its
      verified TOML shape, or reported unsupported when no TOML parser exists.

Apply (write) path:
  devbox mcp import --apply [scope]             Apply selected candidates.
      Interactive TTY  -> multi-select picker of Container-safe candidates.
      Non-interactive  -> requires an explicit selection:
        --server <name>     Apply by server name (repeatable; fails on
                            ambiguity — use --import-id instead).
        --import-id <id>    Apply by stable import id (repeatable).
        --all-applicable    Apply every applicable (container) candidate.
  Applied servers are written to the devbox MCP profile, preserving inherited
  scope (global source -> global profile, project source -> Project profile).
  Inherited secret env VALUES can be copied into a scoped 0600 secret store;
  the summary reports which env KEYS were copied, never their values. Host-only,
  unknown, and excluded candidates are shown but not applied. No Claude Code or
  Codex config is modified yet.

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
    local apply=false
    local all_applicable=false
    local -a projects=()
    local -a servers=()
    local -a import_ids=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --json) json=true ;;
            --all) all=true ;;
            --apply) apply=true ;;
            --all-applicable) all_applicable=true ;;
            --project)
                shift
                if [ "$#" -eq 0 ]; then
                    echo "'mcp import --project' requires a name or path." >&2
                    return 2
                fi
                projects+=("$1")
                ;;
            --project=*) projects+=("${1#--project=}") ;;
            --server)
                shift
                if [ "$#" -eq 0 ]; then
                    echo "'mcp import --server' requires a server name." >&2
                    return 2
                fi
                servers+=("$1")
                ;;
            --server=*) servers+=("${1#--server=}") ;;
            --import-id)
                shift
                if [ "$#" -eq 0 ]; then
                    echo "'mcp import --import-id' requires an id." >&2
                    return 2
                fi
                import_ids+=("$1")
                ;;
            --import-id=*) import_ids+=("${1#--import-id=}") ;;
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

    # Selection flags are only meaningful for an apply. Reject them on a plain
    # dry-run rather than silently ignoring the user's choice.
    if [ "$apply" != true ]; then
        if [ "${#servers[@]}" -gt 0 ] || [ "${#import_ids[@]}" -gt 0 ] \
            || [ "$all_applicable" = true ]; then
            echo "--server/--import-id/--all-applicable require --apply." >&2
            return 2
        fi
        if [ "$json" = true ]; then
            _run_py import-json "${scope_args[@]}"
            return $?
        fi
        # Dry-run by default (ADR 0013 / local-plan-mcp.md decision 10). No writes.
        _run_py import-text "${scope_args[@]}"
        return $?
    fi

    cmd_import_apply "$json" "$all_applicable" \
        scope_args servers import_ids
}

# Run the apply path of `devbox mcp import --apply`. Selection resolution and
# all writes live in the Python core; this function only decides HOW the user
# selected candidates:
#   * explicit --server/--import-id/--all-applicable -> pass straight through;
#   * interactive TTY with no explicit selection -> run a multi-select picker;
#   * non-interactive with no selection -> fail with examples (no writes).
# Array arguments are passed BY NAME (nameref) to avoid re-quoting issues.
cmd_import_apply() {
    local json="$1" all_applicable="$2"
    local -n _scope_args="$3"
    local -n _servers="$4"
    local -n _import_ids="$5"

    local -a sel_args=()
    local s
    for s in "${_servers[@]+"${_servers[@]}"}"; do
        sel_args+=("--server" "$s")
    done
    for s in "${_import_ids[@]+"${_import_ids[@]}"}"; do
        sel_args+=("--import-id" "$s")
    done
    [ "$all_applicable" = true ] && sel_args+=("--all-applicable")

    local have_selection=false
    [ "${#sel_args[@]}" -gt 0 ] && have_selection=true

    if [ "$have_selection" != true ]; then
        # No explicit selection. Interactive -> picker; non-interactive -> fail.
        if [ -t 0 ] && [ -t 1 ]; then
            local picked picker_rc
            # Capture the picker's own exit status: a `! cmd` test would reset
            # $? to 0 inside the then-branch, masking a picker failure.
            picked="$(_apply_picker "${_scope_args[@]}")"
            picker_rc=$?
            if [ "$picker_rc" -ne 0 ]; then
                return "$picker_rc"
            fi
            local -a picked_args=()
            local pline
            while IFS= read -r pline; do
                [ -n "$pline" ] && picked_args+=("--import-id" "$pline")
            done <<< "$picked"
            if [ "${#picked_args[@]}" -eq 0 ]; then
                echo "No candidates selected; nothing applied." >&2
                return 0
            fi
            sel_args=("${picked_args[@]}")
        else
            echo "Non-interactive 'mcp import --apply' needs an explicit selection." >&2
            echo "Examples:" >&2
            echo "  devbox mcp import --apply --server context7" >&2
            echo "  devbox mcp import --apply --import-id imp-abcdef123456" >&2
            echo "  devbox mcp import --apply --all-applicable" >&2
            echo "See 'devbox mcp import' (dry-run) for names and import IDs." >&2
            return 2
        fi
    fi

    if [ "$json" = true ]; then
        _run_py apply-json "${_scope_args[@]}" "${sel_args[@]}"
        return $?
    fi
    _run_py apply-text "${_scope_args[@]}" "${sel_args[@]}"
}

# Interactive multi-select picker for applicable candidates. Lists applicable
# (container-placement) candidates with a number, reads a space/comma-separated
# selection from the TTY, and prints the chosen import IDs (one per line) on
# stdout for the caller. Prompts go to stderr so stdout stays clean. Returns
# non-zero only on a hard error; an empty selection prints nothing and succeeds.
_apply_picker() {
    local applicable
    applicable="$(_run_py list-applicable "$@")"
    if [ -z "$applicable" ]; then
        echo "No applicable (container) candidates to import." >&2
        return 1
    fi

    local -a ids=() names=() scopes=()
    local id name scope
    while IFS=$'\t' read -r id name scope; do
        [ -n "$id" ] || continue
        ids+=("$id")
        names+=("$name")
        scopes+=("$scope")
    done <<< "$applicable"

    echo "Select MCP servers to import (Container-safe candidates):" >&2
    local i
    for i in "${!ids[@]}"; do
        printf '  %2d) %-24s %-12s %s\n' \
            "$((i + 1))" "${names[$i]}" "${scopes[$i]}" "${ids[$i]}" >&2
    done
    printf 'Enter numbers (space/comma separated), or blank to cancel: ' >&2

    local reply
    IFS= read -r reply || reply=""
    reply="${reply//,/ }"

    local token idx
    for token in $reply; do
        case "$token" in
            ''|*[!0-9]*)
                echo "Ignoring invalid selection '$token'." >&2
                continue
                ;;
        esac
        idx="$((token - 1))"
        if [ "$idx" -lt 0 ] || [ "$idx" -ge "${#ids[@]}" ]; then
            echo "Ignoring out-of-range selection '$token'." >&2
            continue
        fi
        printf '%s\n' "${ids[$idx]}"
    done
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

    # Readable inherited table (issue 04): provider, scope, status/placement,
    # runtime, and source columns. Same candidate shape and scope as import,
    # no writes.
    _run_py list-inherited-text "${scope_args[@]}"
}

cmd_render() {
    # Render preview (issue 06): dry-run ONLY. This slice reports the planned
    # Claude Code / Codex config without writing anything. The real write path
    # (and the devbox-mcp-run wrapper) is a later issue, so a bare
    # `devbox mcp render` (apply) is rejected with a clear message.
    local dry_run=false
    local json=false
    local -a projects=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --dry-run) dry_run=true ;;
            --json) json=true ;;
            --project)
                shift
                if [ "$#" -eq 0 ]; then
                    echo "'mcp render --project' requires a name or path." >&2
                    return 2
                fi
                projects+=("$1")
                ;;
            --project=*) projects+=("${1#--project=}") ;;
            -h|--help) _usage; return 0 ;;
            -*)
                echo "Unknown flag for 'mcp render': $1" >&2
                return 2
                ;;
            *)
                echo "Unexpected argument for 'mcp render': $1" >&2
                return 2
                ;;
        esac
        shift
    done

    if [ "$dry_run" != true ]; then
        echo "'devbox mcp render' (apply) is planned but not implemented yet." >&2
        echo "Use 'devbox mcp render --dry-run' to preview planned config." >&2
        return 2
    fi

    # Resolve explicit --project tokens to Claude record keys; render then reads
    # the matching project profile(s). With no --project, every project profile
    # is previewed. --all/--no-global are not meaningful here.
    local -a scope_args=()
    if [ "${#projects[@]}" -gt 0 ]; then
        local token key
        for token in "${projects[@]}"; do
            if ! key="$(_resolve_project_key "$token")"; then
                return 1
            fi
            scope_args+=("--project" "$key")
        done
    fi

    if [ "$json" = true ]; then
        _run_py render-json "${scope_args[@]+"${scope_args[@]}"}"
        return $?
    fi
    _run_py render-text "${scope_args[@]+"${scope_args[@]}"}"
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
        render) cmd_render "$@" ;;
        doctor|add|install|enable|disable|remove)
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
