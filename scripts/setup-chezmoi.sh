#!/bin/bash
set -euo pipefail

# =============================================================================
# Chezmoi dotfiles setup (idempotent - runs on every container start)
# =============================================================================

CHEZMOI_BIN="$HOME/.local/bin/chezmoi"
CHEZMOI_REPO="${CHEZMOI_REPO:-}"

if [ ! -x "$CHEZMOI_BIN" ]; then
    echo "ERROR: chezmoi not found at $CHEZMOI_BIN"
    exit 1
fi

# Init only if not already initialized
if [ ! -d "$HOME/.local/share/chezmoi" ]; then
    if [ -z "$CHEZMOI_REPO" ]; then
        echo "CHEZMOI_REPO not set, skipping chezmoi init"
    else
        echo "Initializing chezmoi from $CHEZMOI_REPO..."
        "$CHEZMOI_BIN" init "$CHEZMOI_REPO"
    fi
else
    echo "Chezmoi already initialized, updating source..."
    "$CHEZMOI_BIN" update --apply=false || true
fi

# Only apply if chezmoi has been initialized
if [ -d "$HOME/.local/share/chezmoi" ]; then
    # Ignore files that are bind-mounted read-only from host
    CHEZMOI_IGNORE="$HOME/.local/share/chezmoi/.chezmoiignore"
    if ! grep -qxF ".config/git/ignore" "$CHEZMOI_IGNORE" 2>/dev/null; then
        echo ".config/git/ignore" >> "$CHEZMOI_IGNORE"
    fi

    # Always apply (idempotent)
    echo "Applying chezmoi dotfiles..."
    "$CHEZMOI_BIN" apply --force

    echo "Chezmoi setup complete"
fi
