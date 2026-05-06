#!/bin/bash
set -euo pipefail
# Seed Claude Code config in /home/node/.claude (= host ~/.claude bind mount).
# See docs/adr/0002 for why we share the dir directly instead of symlinking.
# Devbox-specific defaults are seeded only when the host file is missing,
# so existing host config is never overwritten.

readonly DEFAULTS="/etc/claude-defaults"
readonly TARGET="/home/node/.claude"
readonly PROJECT_NAME="${DEVBOX_PROJECT_NAME:-}"

WARNINGS=()
seeded=0

# First-start. Seed-if-missing — host wins (atomic-rename refresh from host
# or any container is visible to all instances via the shared bind mount).
seed_defaults() {
    [ -d "$DEFAULTS" ] || return 0

    [ -f "$TARGET/settings.json" ] || { cp "$DEFAULTS/settings.json" "$TARGET/settings.json"; seeded=$((seeded+1)); }
    [ -f "$TARGET/statusline-info.sh" ] || { cp "$DEFAULTS/statusline-info.sh" "$TARGET/statusline-info.sh"; seeded=$((seeded+1)); }

    mkdir -p "$TARGET/hooks"
    for hook in "$DEFAULTS/hooks/"*.sh; do
        local name
        name=$(basename "$hook")
        [ -f "$TARGET/hooks/$name" ] || { cp "$hook" "$TARGET/hooks/$name"; seeded=$((seeded+1)); }
    done
}

# Every-start. Backwards-compat alias /workspace/<name> -> host project path
# (ADR 0004). /workspace is created and chown'd to node:node in the Dockerfile,
# so node can write here without sudo.
make_workspace_symlink() {
    [ -n "$PROJECT_NAME" ] || return 0
    [ -n "${DEVBOX_PROJECT_HOST_PATH:-}" ] || return 0
    ln -sfn "$DEVBOX_PROJECT_HOST_PATH" "/workspace/$PROJECT_NAME"
}

# Every-start. Pre-accept trust for both host path and /workspace alias so
# Claude doesn't prompt regardless of which CWD the user enters from.
#
# Multi-instance safety: ~/.claude is bind-mounted (ADR 0002) so concurrent
# container starts race on this file. flock serialises the read-modify-write
# and mktemp gives each process its own staging file — a fixed .tmp name
# would let two redirects truncate each other's content and leave a 0-byte
# file after one of the renames. Self-heals an empty/corrupt .claude.json so
# a survivor of any past race recovers on next start.
pretrust_workspace_paths() {
    [ -n "$PROJECT_NAME" ] || return 0

    local paths=()
    [ -n "${DEVBOX_PROJECT_HOST_PATH:-}" ] && paths+=("$DEVBOX_PROJECT_HOST_PATH")
    paths+=("/workspace/$PROJECT_NAME")

    (
        flock 9

        if [ ! -s "$TARGET/.claude.json" ] \
           || ! jq -e . "$TARGET/.claude.json" >/dev/null 2>&1; then
            echo '{}' > "$TARGET/.claude.json"
        fi

        local needs_update=0 ws
        for ws in "${paths[@]}"; do
            if ! jq -e --arg ws "$ws" \
                '.projects[$ws].hasTrustDialogAccepted == true' \
                "$TARGET/.claude.json" >/dev/null 2>&1; then
                needs_update=1
                break
            fi
        done
        [ "$needs_update" -eq 1 ] || exit 0

        local paths_json tmp
        paths_json=$(printf '%s\n' "${paths[@]}" | jq -R . | jq -s .)
        tmp=$(mktemp "$TARGET/.claude.json.XXXXXX")
        trap 'rm -f "$tmp"' EXIT
        jq --argjson paths "$paths_json" \
            'reduce $paths[] as $ws (.; .projects[$ws].hasTrustDialogAccepted = true)' \
            "$TARGET/.claude.json" > "$tmp"
        mv "$tmp" "$TARGET/.claude.json"
        trap - EXIT
    ) 9>"$TARGET/.claude.json.lock"
}

# One-shot via marker. Marker is in the bind-mounted dir, shared with host
# & all containers, so the notice fires once per host.
show_migration_notice() {
    local marker="$TARGET/.translate-notice-shown"
    [ ! -f "$marker" ] || return 0

    local orphan_count
    orphan_count=$(find "$TARGET/sessions" "$TARGET/projects" \
        -maxdepth 1 -type d -name '-workspace-*' 2>/dev/null | wc -l)
    if [ "$orphan_count" -gt 0 ]; then
        echo
        echo -e "\033[1;33m==> Note: $orphan_count orphaned container session/project dir(s) detected.\033[0m"
        echo "    These were created with the old /workspace/ CWD layout."
        echo "    To make them visible to /resume, run on host:"
        echo -e "      \033[1;36mdevbox migrate --translate-keys\033[0m"
        echo "    (Interactive — asks where each project lives on your host.)"
        echo
    fi
    touch "$marker"
}

# Every-start. zshrc PATH filter ($^path(N-/)) drops missing dirs, so this
# must exist before the shell starts.
ensure_npm_global_path() {
    mkdir -p /usr/local/share/npm-global/bin
}

# First-start (after volume reset). Existing devbox-npm-global volumes
# (created before Codex moved here) don't auto-populate from the image.
bootstrap_codex_cli() {
    [ ! -x /usr/local/share/npm-global/bin/codex ] || return 0
    echo "Bootstrapping Codex CLI into npm-global volume..."
    if npm install -g @openai/codex; then
        echo "Codex CLI installed"
    else
        WARNINGS+=("Codex CLI install failed — run 'npm install -g @openai/codex' manually")
    fi
}

# Every-start. ~/.local/bin/claude lives in the image layer and docker run
# resets it; re-link to the highest version in the RO bind-mounted host dir.
repair_claude_bin() {
    [ -d /home/node/.local/share/claude/versions ] || return 0
    local latest
    latest=$(find /home/node/.local/share/claude/versions/ -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null \
        | sort -V | tail -1)
    [ -n "$latest" ] || return 0
    ln -sf "/home/node/.local/share/claude/versions/$latest" /home/node/.local/bin/claude
    echo "Claude symlink -> $latest"
}

print_summary() {
    if [ "$seeded" -gt 0 ]; then
        echo "Claude Code config seeded ($seeded file(s))"
    else
        echo "Claude Code config OK"
    fi

    if [ "${#WARNINGS[@]}" -gt 0 ]; then
        echo
        echo -e "\033[1;31m==> Setup completed with ${#WARNINGS[@]} warning(s):\033[0m"
        for w in "${WARNINGS[@]}"; do
            echo -e "    \033[1;33m• $w\033[0m"
        done
    fi
}

main() {
    seed_defaults
    make_workspace_symlink     # before pretrust (logical order, not strict dep)
    pretrust_workspace_paths
    show_migration_notice
    ensure_npm_global_path     # must precede bootstrap_codex (shared parent dir)
    bootstrap_codex_cli
    repair_claude_bin
    print_summary
}

main "$@"
