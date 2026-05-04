#!/bin/bash
set -euo pipefail
# Seed Claude Code config in /home/node/.claude (= host ~/.claude bind mount).
# See docs/adr/0002 for why we share the dir directly instead of symlinking.
# Devbox-specific defaults are seeded only when the host file is missing,
# so existing host config is never overwritten.

DEFAULTS="/etc/claude-defaults"
TARGET="/home/node/.claude"
PROJECT_NAME="${DEVBOX_PROJECT_NAME:-}"

[ -d "$DEFAULTS" ] || { echo "No claude defaults found, skipping"; exit 0; }

# Seed devbox defaults only when the host has no equivalent file. Host files
# always win — atomic-rename refresh from host or any container is visible to
# all instances via the shared bind mount.
[ -f "$TARGET/settings.json" ] || cp "$DEFAULTS/settings.json" "$TARGET/settings.json"
[ -f "$TARGET/statusline-info.sh" ] || cp "$DEFAULTS/statusline-info.sh" "$TARGET/statusline-info.sh"

mkdir -p "$TARGET/hooks"
for hook in "$DEFAULTS/hooks/"*.sh; do
    name=$(basename "$hook")
    [ -f "$TARGET/hooks/$name" ] || cp "$hook" "$TARGET/hooks/$name"
done

# Backwards-compat: keep /workspace/<projectname> as an alias for the actual
# project mount. /workspace is created and chown'd to node:node in the
# Dockerfile, so node can write here without sudo. Phase 2 mounts the project
# at the host's absolute path (see docs/adr/0004); the symlink lets users and
# scripts that hardcode /workspace/<name> keep working.
if [ -n "$PROJECT_NAME" ] && [ -n "${DEVBOX_PROJECT_HOST_PATH:-}" ]; then
    ln -sfn "$DEVBOX_PROJECT_HOST_PATH" "/workspace/$PROJECT_NAME"
fi

# Pre-trust the host project path AND the /workspace alias so Claude doesn't
# prompt regardless of which CWD the user enters from.
[ -f "$TARGET/.claude.json" ] || echo '{}' > "$TARGET/.claude.json"
if [ -n "$PROJECT_NAME" ] && [ -f "$TARGET/.claude.json" ]; then
    for ws in "${DEVBOX_PROJECT_HOST_PATH:-}" "/workspace/$PROJECT_NAME"; do
        [ -n "$ws" ] || continue
        jq --arg ws "$ws" '.projects[$ws].hasTrustDialogAccepted = true' \
            "$TARGET/.claude.json" > "$TARGET/.claude.json.tmp" \
            && mv "$TARGET/.claude.json.tmp" "$TARGET/.claude.json"
    done
fi

# One-time notice: if there are orphaned /workspace-keyed sessions/projects
# from the pre-Phase-2 layout, point the user at the translation helper.
# Marker is in the bind-mounted dir — shared with host & all containers, so
# the notice fires once per host. Idempotent.
NOTICE_MARKER="$TARGET/.translate-notice-shown"
if [ ! -f "$NOTICE_MARKER" ]; then
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
    touch "$NOTICE_MARKER"
fi

# Ensure npm-global/bin exists so zshrc path filter ($^path(N-/)) keeps it in PATH
mkdir -p /usr/local/share/npm-global/bin

# Bootstrap Codex CLI in devbox-npm-global volume if missing. Existing volumes
# (created before Codex moved here) don't auto-populate from the image, so we
# install on first start. Idempotent: skips if already present.
if [ ! -x /usr/local/share/npm-global/bin/codex ]; then
    echo "Bootstrapping Codex CLI into npm-global volume..."
    if npm install -g @openai/codex >/dev/null 2>&1; then
        echo "Codex CLI installed"
    else
        echo "Codex CLI install failed - run 'npm install -g @openai/codex' manually"
    fi
fi

# Repair claude symlink: ~/.local/bin/claude lives in the image layer and
# docker run resets it to the image-baked path. Re-link to the highest version
# in the (RO bind-mounted) host claude dir.
if [ -d /home/node/.local/share/claude/versions ]; then
    LATEST=$(find /home/node/.local/share/claude/versions/ -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null \
        | sort -V | tail -1)
    if [ -n "$LATEST" ]; then
        ln -sf "/home/node/.local/share/claude/versions/$LATEST" /home/node/.local/bin/claude
        echo "Claude symlink -> $LATEST"
    fi
fi

echo "Claude Code config seeded"
