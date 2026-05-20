#!/bin/bash
set -euo pipefail
# Idempotent host-side state for `devbox agent-browser` group provisioning (ADR 0010).
#
# Called from install.sh during fresh install (alongside user creation)
# and from `devbox update` as a self-heal for existing installs that
# predate group provisioning — notably macOS installs where the previous
# sysadminctl path left the user in primary group `staff` and never
# created a matching `devbox-agent` group.
#
# Linux/WSL2: `useradd --user-group` always co-creates the matching group
# at user-creation time, so this script's only useful action there is
# adding the invoking user to the group.
#
# macOS: pre-existing devbox-agent users from older installs have no
# matching group and primary group `staff`. Without a self-heal,
# `chown devbox-agent:` on archive files resolves to `staff`, which
# everyone on macOS is in — defeating the ADR 0010 tamper-proof
# property that the user-group-membership read path provides.

DEVBOX_DIR="$(cd "$(dirname "$0")/.." && pwd)"
QUIET_IF_NOOP=false

for arg in "$@"; do
    case "$arg" in
        --quiet-if-noop) QUIET_IF_NOOP=true ;;
        -h|--help)
            cat <<EOF
Usage: ensure-agent-browser-host-state.sh [--quiet-if-noop]

Self-heals devbox-agent group provisioning and developer group
membership for the agent-browser feature.

Options:
  --quiet-if-noop   Suppress output when nothing needed to be done.
EOF
            exit 0 ;;
        *)
            echo "ensure-agent-browser-host-state.sh: unknown arg '$arg'" >&2
            exit 2 ;;
    esac
done

log() { $QUIET_IF_NOOP || printf '%s\n' "$*"; }
loud() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

# shellcheck source=../lib/host-platform.sh disable=SC1091
. "$DEVBOX_DIR/lib/host-platform.sh"

platform="$(host_platform::detect)" || { warn "unknown platform"; exit 1; }

actions=0

# Active migration for break-fix: when an existing install pulled the
# agent-browser feature but never ran `bash install.sh`, the devbox-agent
# OS user is missing entirely. Without this branch, `devbox update`
# self-heal would silently skip user provisioning and the next
# `devbox agent-browser start` would fail with "user does not exist".
# Per the feedback_active_migration_for_breakfix rule, break-fix lives
# in `devbox update`, not in warn-only output.
if ! id devbox-agent >/dev/null 2>&1; then
    loud "Creating devbox-agent OS user (sudo may prompt)..."
    if ! host_platform::ensure_agent_user; then
        warn "Failed to create devbox-agent user. Run 'bash install.sh' for full setup with diagnostics."
        exit 1
    fi
    loud "Created devbox-agent user"
    actions=$((actions + 1))
fi

# macOS self-heal: group existence + primary group binding on the user.
if [ "$platform" = "macos" ]; then
    if ! dseditgroup -o read devbox-agent >/dev/null 2>&1; then
        if ! sudo dseditgroup -o create devbox-agent; then
            warn "Failed to create devbox-agent group on macOS."
            exit 1
        fi
        loud "Created devbox-agent group"
        actions=$((actions + 1))
    fi

    local_pgid="$(dscl . -read /Users/devbox-agent PrimaryGroupID 2>/dev/null \
        | awk '/PrimaryGroupID:/ {print $2}')"
    target_pgid="$(dscl . -read /Groups/devbox-agent PrimaryGroupID 2>/dev/null \
        | awk '/PrimaryGroupID:/ {print $2}')"
    primary_group_changed=false
    if [ -n "$local_pgid" ] && [ -n "$target_pgid" ] && [ "$local_pgid" != "$target_pgid" ]; then
        if ! sudo dscl . -create /Users/devbox-agent PrimaryGroupID "$target_pgid"; then
            warn "Failed to set devbox-agent primary group to devbox-agent ($target_pgid)."
            exit 1
        fi
        loud "Set devbox-agent primary group to devbox-agent ($target_pgid)"
        actions=$((actions + 1))
        primary_group_changed=true
    fi

    # Re-chown any pre-existing archive dir whose group is still `staff`
    # from before the primary-group migration. `chown devbox-agent:` on a
    # macOS install with the old primary group would have created files
    # in `staff`, leaving them accessible to every macOS user. After the
    # primary group fix above, all NEW files land in `devbox-agent` —
    # but existing ones need a one-shot recursive repair.
    if [ "$primary_group_changed" = true ] && [ -d /var/log/devbox/agent-browser ]; then
        if ! sudo chown -R devbox-agent: /var/log/devbox/agent-browser; then
            warn "Failed to re-chown existing /var/log/devbox/agent-browser to devbox-agent's primary group."
        else
            loud "Re-chowned existing /var/log/devbox/agent-browser to devbox-agent:devbox-agent"
            actions=$((actions + 1))
        fi
    fi
fi

# Universal: invoking user in devbox-agent group.
invoker="${USER:-$(id -un)}"
if ! id -nG "$invoker" 2>/dev/null | tr ' ' '\n' | grep -qx devbox-agent; then
    if host_platform::ensure_agent_user_in_group "$invoker"; then
        loud "Added $invoker to devbox-agent group (re-login or 'newgrp devbox-agent' to apply)"
        actions=$((actions + 1))
    else
        warn "Failed to add $invoker to devbox-agent group."
        exit 1
    fi
fi

if [ "$actions" -eq 0 ]; then
    log "Agent-browser host state already provisioned (no changes)."
fi
