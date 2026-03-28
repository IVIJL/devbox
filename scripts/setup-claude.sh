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

# Sync skills from host bind mount (additive — never removes container-only skills)
if [ -d /home/node/.host-config/claude/skills ]; then
    mkdir -p "$TARGET/skills"
    rsync -a /home/node/.host-config/claude/skills/ "$TARGET/skills/"
    echo "Skills synced from host"
fi

# Symlink user-level CLAUDE.md from host bind mount (live, directory mount)
if [ -f /home/node/.host-config/claude/CLAUDE.md ]; then
    ln -sf /home/node/.host-config/claude/CLAUDE.md "$TARGET/CLAUDE.md"
fi

# Copy credentials from host only when no setup-token is provided.
# When CLAUDE_CODE_OAUTH_TOKEN is set, Claude uses it directly — no file needed.
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -f /home/node/.host-config/claude/.credentials.json ]; then
    cp /home/node/.host-config/claude/.credentials.json "$TARGET/.credentials.json"
fi

# Copy host ~/.claude.json into CLAUDE_CONFIG_DIR (onboarding state, account info, prefs).
# Claude Code reads hasCompletedOnboarding from this path; without it every new
# per-project container shows the login screen.
if [ -f /home/node/.host-config/claude.json ]; then
    cp /home/node/.host-config/claude.json "$TARGET/.claude.json"
fi

# Pre-trust /workspace so the safety prompt doesn't appear on every startup
if [ -f "$TARGET/.claude.json" ]; then
    jq '.projects["/workspace"].hasTrustDialogAccepted = true' "$TARGET/.claude.json" > "$TARGET/.claude.json.tmp" \
        && mv "$TARGET/.claude.json.tmp" "$TARGET/.claude.json"
fi

# Ensure npm-global/bin exists so zshrc path filter ($^path(N-/)) keeps it in PATH
mkdir -p /usr/local/share/npm-global/bin

echo "Claude Code config seeded from image defaults"
