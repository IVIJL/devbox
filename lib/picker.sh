# shellcheck shell=bash
# =============================================================================
# Devbox interactive picker — single + multi select with consistent UX
# =============================================================================
# Sourced by docker-run.sh (host). Reads items from stdin (one per line),
# prints the selection on stdout. fzf is preferred when available; a numbered
# fallback handles the no-fzf case with `a` (first-option) and `q` (cancel)
# shortcuts and comma-separated multi-select (`1,3,5`).
#
# Public API:
#   picker::one  --prompt "<p>" [--first-option "<s>"]
#   picker::many --prompt "<p>" [--first-option "<s>"]
#
# When --first-option is set, the option string is prepended to the list and
# `a)` becomes a shortcut for it. Caller string-compares the returned value
# against its first-option to detect "expand all".
#
# Override fzf detection (for tests): export DEVBOX_PICKER_FZF=0
# See docs/adr/0006-interactive-picker-conventions.md.
# =============================================================================

# --- Public API --------------------------------------------------------------

# Pick a single item. See header comment for arguments.
picker::one() {
    _picker::run one "$@"
}

# Pick one or more items. See header comment for arguments.
picker::many() {
    _picker::run many "$@"
}

# --- Private -----------------------------------------------------------------

_picker::run() {
    local mode="$1"; shift
    local prompt="" first_option=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --prompt)       prompt="$2"; shift 2 ;;
            --first-option) first_option="$2"; shift 2 ;;
            *) echo "picker: unknown arg: $1" >&2; return 1 ;;
        esac
    done

    local raw_items
    raw_items=$(cat)
    [ -z "$raw_items" ] && return 1

    local -a items=()
    if [ -n "$first_option" ]; then
        items+=("$first_option")
    fi
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        items+=("$line")
    done <<< "$raw_items"

    if _picker::fzf_available; then
        _picker::fzf "$mode" "$prompt" "${items[@]}"
    else
        _picker::fallback "$mode" "$prompt" "$first_option" "${items[@]}"
    fi
}

_picker::fzf_available() {
    [ "${DEVBOX_PICKER_FZF:-1}" != "0" ] && command -v fzf &>/dev/null
}

_picker::fzf() {
    local mode="$1" prompt="$2"; shift 2
    local args=(--prompt="$prompt")
    [ "$mode" = many ] && args+=(--multi)
    printf '%s\n' "$@" | fzf "${args[@]}" || return 1
}

_picker::fallback() {
    local mode="$1" prompt="$2" first_option="$3"; shift 3
    local -a items=("$@")
    local has_first=0
    if [ -n "$first_option" ] && [ "${items[0]:-}" = "$first_option" ]; then
        has_first=1
    fi

    echo "" >&2
    local i
    if [ "$has_first" = 1 ]; then
        echo "  a) ${items[0]}" >&2
        for ((i = 1; i < ${#items[@]}; i++)); do
            printf "  %d) %s\n" "$i" "${items[$i]}" >&2
        done
    else
        for ((i = 0; i < ${#items[@]}; i++)); do
            printf "  %d) %s\n" "$((i + 1))" "${items[$i]}" >&2
        done
    fi
    echo "  q) Cancel" >&2
    echo "" >&2

    local hint
    if [ "$mode" = many ]; then
        hint="(comma-separated numbers$([ "$has_first" = 1 ] && echo ", a")/q)"
    else
        hint="(number$([ "$has_first" = 1 ] && echo "/a")/q)"
    fi
    printf "%s %s: " "$prompt" "$hint" >&2

    local choice
    choice=$(_picker::read_choice) || return 1
    _picker::select "$mode" "$first_option" "$choice" "${items[@]}"
}

# Read a single line from the controlling terminal.
#
# The caller pipes items into picker via stdin, so by the time the fallback
# prompt runs, the function's stdin is at EOF. We redirect `read` from
# /dev/tty to break that coupling. Tests stub this by exporting
# DEVBOX_PICKER_TEST_CHOICE (set-but-empty = simulated Enter = cancel).
_picker::read_choice() {
    if [ -n "${DEVBOX_PICKER_TEST_CHOICE+x}" ]; then
        printf '%s' "$DEVBOX_PICKER_TEST_CHOICE"
        return 0
    fi
    local choice
    IFS= read -r choice </dev/tty || return 1
    printf '%s' "$choice"
}

# Pure selection logic. Inputs: mode (one|many), first_option, choice string,
# items (already including first_option as items[0] if set). With
# first-option, item indices in $choice are 1-based over the **non-first**
# items (i.e. the user types `1` for the first real item, not the sentinel).
#
# Stdout: selected item(s), newline-separated. Returns 1 on cancel/invalid.
_picker::select() {
    local mode="$1" first_option="$2" choice="$3"; shift 3
    local -a items=("$@")
    local has_first=0
    if [ -n "$first_option" ] && [ "${items[0]:-}" = "$first_option" ]; then
        has_first=1
    fi

    # Trim whitespace
    choice="${choice#"${choice%%[![:space:]]*}"}"
    choice="${choice%"${choice##*[![:space:]]}"}"

    case "$choice" in
        q|"") return 1 ;;
    esac

    if [ "$choice" = "a" ]; then
        if [ "$has_first" = 1 ]; then
            printf '%s\n' "$first_option"
            return 0
        fi
        echo "Invalid choice: a" >&2
        return 1
    fi

    local offset=0
    [ "$has_first" = 1 ] && offset=1
    local max=$((${#items[@]} - offset))

    if [ "$mode" = many ]; then
        local -a raw=()
        IFS=',' read -ra raw <<< "$choice"
        local idx
        local -a picked=()
        for idx in "${raw[@]}"; do
            idx="${idx// /}"
            if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -lt 1 ] || [ "$idx" -gt "$max" ]; then
                echo "Invalid choice: $idx" >&2
                return 1
            fi
            picked+=("${items[$((offset + idx - 1))]}")
        done
        printf '%s\n' "${picked[@]}"
    else
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$max" ]; then
            echo "Invalid choice." >&2
            return 1
        fi
        printf '%s\n' "${items[$((offset + choice - 1))]}"
    fi
}
