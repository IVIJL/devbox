#!/bin/bash
set -euo pipefail
# Seed Claude Code config from image defaults into the persistent volume.
# Settings/hooks are always refreshed; credentials & runtime state are untouched.

DEFAULTS="/etc/claude-defaults"
TARGET="/home/node/.claude"

[ -d "$DEFAULTS" ] || { echo "No claude defaults found, skipping"; exit 0; }

# Ensure .claude.json exists (prevents "config not found" warnings on fresh volume)
if [ ! -f "$TARGET/.claude.json" ]; then
    if ls "$TARGET/backups/.claude.json.backup."* &>/dev/null; then
        # Restore from most recent backup
        latest=$(ls -t "$TARGET/backups/.claude.json.backup."* | head -1)
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

echo "Claude Code config seeded from image defaults"
