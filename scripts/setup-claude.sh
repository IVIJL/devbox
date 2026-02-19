#!/bin/bash
set -euo pipefail
# Seed Claude Code config from image defaults into the persistent volume.
# Settings/hooks are always refreshed; credentials & runtime state are untouched.

DEFAULTS="/etc/claude-defaults"
TARGET="/home/node/.claude"

[ -d "$DEFAULTS" ] || { echo "No claude defaults found, skipping"; exit 0; }

# Always overwrite declarative config
cp "$DEFAULTS/settings.json" "$TARGET/settings.json"
cp "$DEFAULTS/statusline-info.sh" "$TARGET/statusline-info.sh"

# Always overwrite hooks directory
mkdir -p "$TARGET/hooks"
cp "$DEFAULTS/hooks/"*.sh "$TARGET/hooks/"

echo "Claude Code config seeded from image defaults"
