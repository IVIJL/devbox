#!/bin/bash
set -euo pipefail
# Seed Claude Code config from image defaults into the shared volume.
# Settings/hooks are always refreshed; credentials are symlinked to host bind mount.

DEFAULTS="/etc/claude-defaults"
TARGET="/home/node/.claude"
HOST="/home/node/.claude-host"
PROJECT_NAME="${DEVBOX_PROJECT_NAME:-}"

[ -d "$DEFAULTS" ] || { echo "No claude defaults found, skipping"; exit 0; }

# Ensure .claude.json exists (prevents "config not found" warnings on fresh volume)
if [ ! -f "$TARGET/.claude.json" ]; then
    if [ -f "$HOST/.claude.json" ]; then
        cp "$HOST/.claude.json" "$TARGET/.claude.json"
        echo "Copied .claude.json from host"
    elif compgen -G "$TARGET/backups/.claude.json.backup.*" >/dev/null; then
        latest=$(find "$TARGET/backups" -name '.claude.json.backup.*' -printf '%T@ %p\n' | sort -rn | head -1 | cut -d' ' -f2-)
        cp "$latest" "$TARGET/.claude.json"
        echo "Restored .claude.json from backup"
    else
        echo '{}' > "$TARGET/.claude.json"
        echo "Created empty .claude.json"
    fi
fi

# Always overwrite declarative config (devbox-specific)
cp "$DEFAULTS/settings.json" "$TARGET/settings.json"
cp "$DEFAULTS/statusline-info.sh" "$TARGET/statusline-info.sh"
mkdir -p "$TARGET/hooks"
cp "$DEFAULTS/hooks/"*.sh "$TARGET/hooks/"

# Symlink credentials + lock to host bind mount (shared OAuth with host)
if [ -d "$HOST" ]; then
    for f in .credentials.json .credentials.lock; do
        if [ -f "$HOST/$f" ] || [ "$f" = ".credentials.lock" ]; then
            ln -sf "$HOST/$f" "$TARGET/$f"
        fi
    done

    # Symlink CLAUDE.md from host (live, follows host changes)
    if [ -f "$HOST/CLAUDE.md" ]; then
        ln -sf "$HOST/CLAUDE.md" "$TARGET/CLAUDE.md"
    fi

    # Sync skills from host (additive — never removes container-only skills)
    if [ -d "$HOST/skills" ]; then
        mkdir -p "$TARGET/skills"
        rsync -a "$HOST/skills/" "$TARGET/skills/"
        echo "Skills synced from host"
    fi

    # Sync plugins from host (marketplace repos, cache, config)
    if [ -d "$HOST/plugins" ]; then
        rsync -a "$HOST/plugins/" "$TARGET/plugins/"
        # Fix host-specific absolute paths in plugin registries
        if [ -n "${HOST_HOME:-}" ]; then
            for pfile in installed_plugins.json known_marketplaces.json; do
                if [ -f "$TARGET/plugins/$pfile" ]; then
                    sed -i "s|${HOST_HOME}/.claude|/home/node/.claude|g" "$TARGET/plugins/$pfile"
                fi
            done
        fi
        echo "Plugins synced from host"
    fi
fi

# Pre-trust /workspace/<project> so the safety prompt doesn't appear on every startup
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

# Repair claude symlink: ~/.local/bin/claude lives in the image layer (not in
# the devbox-claude-bin volume), so docker run resets it to the image-baked
# version. Pick the highest-versioned binary in the persisted volume and re-link.
if [ -d /home/node/.local/share/claude/versions ]; then
    LATEST=$(find /home/node/.local/share/claude/versions/ -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null \
        | sort -V | tail -1)
    if [ -n "$LATEST" ]; then
        ln -sf "/home/node/.local/share/claude/versions/$LATEST" /home/node/.local/bin/claude
        echo "Claude symlink -> $LATEST"
    fi
fi

echo "Claude Code config seeded from image defaults"
