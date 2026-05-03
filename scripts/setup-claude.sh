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

# Pre-trust /workspace/<project> so the safety prompt doesn't appear on every startup
[ -f "$TARGET/.claude.json" ] || echo '{}' > "$TARGET/.claude.json"
if [ -n "$PROJECT_NAME" ] && [ -f "$TARGET/.claude.json" ]; then
    WORKSPACE="/workspace/$PROJECT_NAME"
    jq --arg ws "$WORKSPACE" '.projects[$ws].hasTrustDialogAccepted = true' \
        "$TARGET/.claude.json" > "$TARGET/.claude.json.tmp" \
        && mv "$TARGET/.claude.json.tmp" "$TARGET/.claude.json"
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
