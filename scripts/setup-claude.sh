#!/bin/bash
set -euo pipefail
# Seed Claude Code config from image defaults into the persistent volume.
# Settings/hooks are always refreshed; credentials & runtime state are untouched.

DEFAULTS="/etc/claude-defaults"
TARGET="/home/node/.claude"

[ -d "$DEFAULTS" ] || { echo "No claude defaults found, skipping"; exit 0; }

# Ensure .claude.json exists (prevents "config not found" warnings on fresh volume)
if [ ! -f "$TARGET/.claude.json" ]; then
    if compgen -G "$TARGET/backups/.claude.json.backup.*" >/dev/null; then
        # Restore from most recent backup
        latest=$(find "$TARGET/backups" -name '.claude.json.backup.*' -printf '%T@ %p\n' | sort -rn | head -1 | cut -d' ' -f2-)
        cp "$latest" "$TARGET/.claude.json"
        echo "Restored .claude.json from backup"
    else
        echo '{}' > "$TARGET/.claude.json"
        echo "Created empty .claude.json"
    fi
fi

# Always overwrite declarative config
cp "$DEFAULTS/settings.json" "$TARGET/settings.json"
cp "$DEFAULTS/statusline-info.sh" "$TARGET/statusline-info.sh"

# Always overwrite hooks directory
mkdir -p "$TARGET/hooks"
cp "$DEFAULTS/hooks/"*.sh "$TARGET/hooks/"

# Symlink user-level CLAUDE.md from host bind mount (live, directory mount)
if [ -f /home/node/.host-config/claude/CLAUDE.md ]; then
    ln -sf /home/node/.host-config/claude/CLAUDE.md "$TARGET/CLAUDE.md"
fi

# Copy credentials from host (writable copy so Claude can refresh tokens)
if [ -f /home/node/.host-config/claude/.credentials.json ]; then
    cp /home/node/.host-config/claude/.credentials.json "$TARGET/.credentials.json"
fi

# Copy ~/.claude.json from host (onboarding state, account info)
# Writable copy so Claude Code can update it during the session.
if [ -f /home/node/.host-config/claude.json ]; then
    cp /home/node/.host-config/claude.json /home/node/.claude.json
fi

echo "Claude Code config seeded from image defaults"
