#!/bin/bash
set -euo pipefail

# =============================================================================
# Devbox — portable dev container with default-deny firewall
# =============================================================================
# Run 'devbox --help' for usage information.
# Install: sudo ln -s /path/to/devbox/docker-run.sh /usr/local/bin/devbox
# =============================================================================

show_help() {
    cat <<'EOF'
Devbox — portable dev container with default-deny firewall

Usage:
  devbox [--ssh-config] [path]     Start/attach container for project
  devbox <name>                    Attach to running devbox-<name>
  devbox ls                        List running containers
  devbox stop [name] [--clean]     Stop container (--clean removes volumes)
  devbox remove [name]             Remove project data (volumes)
  devbox port <port>               Expose port via Traefik
  devbox ports                     List active port routes
  devbox build [flags]             Build/rebuild the devbox image
  devbox update                    Update devbox (pull repo + rebuild image)
  devbox migrate                   Migrate data to new layout (interactive; auto-run by 'devbox update')
  devbox migrate-naming            Rename legacy non-LDH containers/volumes (auto-run by 'devbox update')
  devbox uninstall                 Remove everything (containers, volumes, image)
  devbox prune [--all]             Remove old build cache (--all = everything)
  devbox claude-token              Generate/regenerate Claude Code token
  devbox allow [domain]            List or add allowed firewall domain
                                   (entry matches domain + all subdomains)
  devbox deny [domain]             Remove allowed domain (interactive)
  devbox blocked                   Show blocked DNS queries, allow interactively
  devbox cursor [name]             Open Cursor attached to running devbox
  devbox code [name]               Open VS Code attached to running devbox
  devbox clip                      Grab clipboard image for container use
  devbox sync-skills               Sync host skills to all running containers
  devbox ssh-config [add|edit]     Manage devbox SSH config

Build flags:
  devbox build                     Build image (uses cache)
  devbox build --no-cache          Full rebuild without cache
  devbox build --clean             Full reset (volumes + cache) + rebuild
  devbox build --progress=plain    Show full build log

Examples:
  devbox                           Mount CWD at host project path inside container
  devbox ~/projects/app            Mount specific project
  devbox --ssh-config ~/app        Mount with full host SSH config
  devbox ssh-config add            Add SSH host to devbox config
  devbox cursor                     Open Cursor for CWD project
  devbox cursor my-app              Open Cursor for specific devbox
  devbox code                       Open VS Code for CWD project
  devbox code my-app                Open VS Code for specific devbox
  devbox stop my-app               Stop specific container
  devbox stop --clean              Stop + remove Docker/history volumes
  devbox remove                    Interactive project data cleanup
  devbox port 3000                 Route 3000.<project>.127.0.0.1.traefik.me
  devbox allow pypi.org            Allow pypi.org (and *.pypi.org) through firewall
  devbox deny                      Interactive domain removal
  devbox blocked                   See blocked queries, allow with fzf
EOF
    exit 0
}

IMAGE="vlcak/devbox:latest"
SSH_WARNING=""
DEVBOX_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
TRAEFIK_CONFIG_DIR="$HOME/.config/devbox/traefik/dynamic"

# Allowlist module — defines ALLOWLIST_HOST_FILE, IPSET_NAME, allowlist::* fns
# shellcheck source=lib/allowlist.sh
source "$DEVBOX_DIR/lib/allowlist.sh"

# Naming module — owns the format of container names, volumes, hostname,
# workspace alias and traefik route hosts. See lib/naming.sh and
# docs/adr/0005-project-naming-from-sanitized-basename.md.
# shellcheck source=lib/naming.sh
source "$DEVBOX_DIR/lib/naming.sh"

# Picker module — single + multi interactive selection with consistent UX
# across fzf and the no-fzf fallback. See lib/picker.sh and
# docs/adr/0006-interactive-picker-conventions.md.
# shellcheck source=lib/picker.sh
source "$DEVBOX_DIR/lib/picker.sh"

# Migrate from old ~/.devbox to ~/.config/devbox
if [ -d "$HOME/.devbox" ] && [ ! -d "$HOME/.config/devbox" ]; then
    echo "Migrating config: ~/.devbox → ~/.config/devbox"
    mkdir -p "$HOME/.config"
    mv "$HOME/.devbox" "$HOME/.config/devbox"
fi

# --- Helper functions --------------------------------------------------------

# Percent-encode a filesystem path for embedding in a URI path component.
# RFC 3986 unreserved chars and `/` pass through; everything else is
# %-encoded. Needed because host project paths can contain spaces or
# diacritics (e.g. ~/Code/My App) that would otherwise produce an invalid
# folder URI for vscode-remote://.
url_encode_path() {
    local LC_ALL=C s="$1" out="" c
    local -i i
    for ((i=0; i<${#s}; i++)); do
        c="${s:$i:1}"
        case "$c" in
            [a-zA-Z0-9._~/-]) out+="$c" ;;
            *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
        esac
    done
    printf '%s' "$out"
}

set_tab_title() {
    # shellcheck disable=SC1003 # literal backslash for OSC escape terminator
    printf '\033]0;%s\033\\' "$1"
}

bootstrap_traefik() {
    docker network inspect devproxy >/dev/null 2>&1 || docker network create devproxy

    mkdir -p "$TRAEFIK_CONFIG_DIR"
    seed_allowed_domains
    seed_default_ports

    # If traefik exists but is exited, restart it
    if docker ps -a --filter "name=^devbox-traefik$" --filter "status=exited" --format '{{.ID}}' | grep -q .; then
        echo "Restarting Traefik proxy..."
        docker start devbox-traefik
        return
    fi

    if ! docker ps --format '{{.Names}}' | grep -qx devbox-traefik; then
        echo "Starting Traefik proxy..."
        docker run -d --name devbox-traefik --restart unless-stopped \
            --network devproxy \
            -p 127.0.0.1:80:80 \
            -v /var/run/docker.sock:/var/run/docker.sock:ro \
            -v "$TRAEFIK_CONFIG_DIR:/etc/traefik/dynamic:ro" \
            traefik:v3 \
            --providers.docker=true \
            --providers.docker.exposedbydefault=false \
            --providers.docker.network=devproxy \
            --providers.file.directory=/etc/traefik/dynamic \
            --providers.file.watch=true \
            --entrypoints.web.address=:80
    fi
}

seed_allowed_domains() {
    allowlist::ensure_seeded "$ALLOWLIST_HOST_FILE" "$DEVBOX_DIR/config/default-allowlist.conf"
}

seed_default_ports() {
    local ports_file="$HOME/.config/devbox/default-ports.conf"
    mkdir -p "$HOME/.config/devbox"
    if [ ! -f "$ports_file" ]; then
        cat > "$ports_file" <<'PORTS'
3000
3001
4173
4200
5000
5173
5174
8000
8080
8081
8090
8888
9000
9090
PORTS
    fi
    # Ensure required ports are present (e.g. markdown-preview on 8090)
    grep -qxF "8090" "$ports_file" 2>/dev/null || echo "8090" >> "$ports_file"
}

apply_port_routes() {
    local container="$1"
    local project="${container#devbox-}"
    local ports_file="$HOME/.config/devbox/default-ports.conf"
    [ -f "$ports_file" ] || return 0

    while read -r port _rest; do
        port="${port%%#*}"
        [ -z "$port" ] && continue

        local host_rule
        host_rule="$(devbox::route_host "$project" "$port")"
        local config_file="${TRAEFIK_CONFIG_DIR}/${container}-${port}.yml"
        local router_name="${container}-${port}"

        cat > "$config_file" <<YAML
http:
  routers:
    ${router_name}:
      rule: "Host(\`${host_rule}\`)"
      entryPoints:
        - web
      service: ${router_name}
  services:
    ${router_name}:
      loadBalancer:
        servers:
          - url: "http://${container}:${port}"
YAML
    done < "$ports_file"
}

# Gracefully stop a devbox container — stop inner DinD containers first
graceful_stop_container() {
    local name="$1"
    docker exec -u node "$name" bash -c '
        if [ -S "$XDG_RUNTIME_DIR/docker.sock" ] && docker info >/dev/null 2>&1; then
            inner=$(docker ps --format "{{.ID}} {{.Names}}" 2>/dev/null)
            if [ -n "$inner" ]; then
                echo "Stopping inner containers..."
                while read -r cid cname; do
                    echo "  Stopping: $cname ($cid)"
                    docker stop -t 30 "$cid" >/dev/null 2>&1 || true
                done <<< "$inner"
            fi
        fi
    ' 2>/dev/null || true
    docker stop -t 15 "$name" > /dev/null 2>&1 || true
}

stop_traefik_if_idle() {
    local remaining
    remaining=$(docker ps --filter "name=^devbox-" --format '{{.Names}}' | grep -v '^devbox-traefik$' || true)
    if [ -z "$remaining" ] && docker ps --format '{{.Names}}' | grep -qx devbox-traefik; then
        docker stop devbox-traefik > /dev/null
        docker rm devbox-traefik > /dev/null
        echo "Stopped: devbox-traefik (no remaining containers)"
    fi
}

attach_to_container() {
    local name="$1"
    echo "Attaching to running container: $name"
    set_tab_title "${name#devbox-}"
    # Prefer the host project path advertised by Phase 2 containers; fall back
    # to /workspace/<name> for legacy containers that pre-date this layout.
    local ws
    ws=$(docker exec -u node "$name" sh -c 'printf %s "$DEVBOX_PROJECT_HOST_PATH"' 2>/dev/null || true)
    if [ -z "$ws" ] || ! docker exec -u node "$name" test -d "$ws" 2>/dev/null; then
        ws="/workspace/${name#devbox-}"
        if ! docker exec -u node "$name" test -d "$ws" 2>/dev/null; then
            ws="/workspace"
        fi
    fi
    exec docker exec -it -u node -w "$ws" "$name" zsh
}

# Restart an exited devbox container and re-run init scripts
# Returns 1 if restart fails (stale mounts after reboot) — caller should recreate
restart_exited_container() {
    local name="$1"
    echo "Restarting exited container: $name"
    if ! docker start "$name" 2>/dev/null; then
        echo "Restart failed (stale mounts?), removing dead container..."
        docker rm "$name" > /dev/null
        return 1
    fi
    # Root-context setup (firewall, gitconfig, host-home symlink) is handled by
    # the entrypoint on every container start. Here we only run the user-mode
    # setup as node.
    docker exec -u node "$name" bash -c \
        '/usr/local/bin/start-rootless-docker.sh && /usr/local/bin/setup-chezmoi.sh && /usr/local/bin/setup-claude.sh'
    # Re-apply port routes
    apply_port_routes "$name"
}

list_running_containers() {
    local containers
    containers=$(docker ps --filter "name=^devbox-" --format '{{.Names}}\t{{.Status}}\t{{.RunningFor}}' | grep -v '^devbox-traefik\b' || true)
    if [ -z "$containers" ]; then
        echo "No running devbox containers."
    else
        printf '%-25s %-50s %s\n' "NAME" "URL" "STATUS"
        while IFS=$'\t' read -r name status running; do
            local project url
            project="${name#devbox-}"
            url="http://$(devbox::route_host "$project" '<port>')"
            printf '%-25s %-50s %s\n' "$name" "$url" "$status"
        done <<< "$containers"
    fi

    local exited
    exited=$(docker ps -a --filter "name=^devbox-" --filter "status=exited" \
        --format '{{.Names}}\t{{.Status}}' | grep -v '^devbox-traefik\b' || true)
    if [ -n "$exited" ]; then
        echo ""
        echo "Exited (use 'devbox <name>' to restart):"
        while IFS=$'\t' read -r name status; do
            printf '  %-25s %s\n' "$name" "$status"
        done <<< "$exited"
    fi
}

# Trigger dnsmasq config reload in all running devbox containers.
# Implementation lives in /usr/local/bin/devbox-firewall-reload (in the image);
# this is just the per-container fan-out.
#
# Usage:
#   reload_firewall_in_containers                  # plain reload
#   reload_firewall_in_containers allow <domain>   # warm DNS cache for new domain
#   reload_firewall_in_containers deny  "<doms>"   # space-separated domains to drop from ipset
reload_firewall_in_containers() {
    local action="${1:-}"
    local domains="${2:-}"
    local containers
    containers=$(docker ps --filter "name=^devbox-" --format '{{.Names}}' | grep -v '^devbox-traefik$' || true)
    [ -z "$containers" ] && return 0
    while IFS= read -r container; do
        if docker exec -u root "$container" /usr/local/bin/devbox-firewall-reload "$action" "$domains"; then
            echo "  Reloaded: $container"
        else
            echo "  Failed: $container" >&2
        fi
    done <<< "$containers"
}

# Thin wrapper around picker::one for devbox containers.
# $1 = prompt text, $2 = optionally "with_all" to add "stop all" sentinel.
# Returns selected name on stdout, 1 on cancel/empty.
pick_container() {
    local prompt="$1" with_all="${2:-}"
    local running
    running=$(docker ps -a --filter "name=^devbox-" --format '{{.Names}}' | grep -v '^devbox-traefik$' || true)

    if [ -z "$running" ]; then
        echo "No devbox containers." >&2
        return 1
    fi

    local args=(--prompt "$prompt")
    [ "$with_all" = "with_all" ] && args+=(--first-option "* Stop all")
    printf '%s\n' "$running" | picker::one "${args[@]}"
}

# Open an IDE attached to a devbox container ($1 = cursor|code, $2 = optional target).
attach_ide() {
    local ide="$1" target="${2:-}"
    local binary display_name install_hint
    case "$ide" in
        cursor)
            binary=cursor
            display_name="Cursor"
            install_hint="Cursor → Cmd+Shift+P → 'Install cursor command in PATH'"
            ;;
        code)
            binary=code
            display_name="VS Code"
            install_hint="VS Code → Cmd+Shift+P → 'Install code command in PATH'"
            ;;
        *)
            echo "Unknown IDE: $ide" >&2
            exit 1
            ;;
    esac

    if ! command -v "$binary" &>/dev/null; then
        echo "Error: '$binary' CLI not found in PATH." >&2
        echo "Install it: $install_hint" >&2
        exit 1
    fi

    if [ -n "$target" ]; then
        devbox::names_from_token "$target"
    else
        devbox::names_from_path "$(pwd)"
    fi
    local container="$DEVBOX_CONTAINER_NAME"

    if ! docker ps --filter "name=^${container}$" --format '{{.Names}}' | grep -q .; then
        echo "Container $container is not running." >&2
        container=$(pick_container "Select container: ") || exit 1
    fi

    local hostpath
    hostpath=$(docker exec "$container" sh -c 'printf %s "$DEVBOX_PROJECT_HOST_PATH"' 2>/dev/null || true)
    if [ -z "$hostpath" ]; then
        echo "Container $container predates Phase 2 layout (ADR 0004)." >&2
        echo "Restart it to pick up the new mount: devbox stop $container && devbox" >&2
        exit 1
    fi

    local attach_json="{\"containerName\":\"/${container}\"}"
    local hex
    if command -v xxd &>/dev/null; then
        hex=$(printf '%s' "$attach_json" | xxd -p | tr -d '\n')
    else
        hex=$(printf '%s' "$attach_json" | od -A n -t x1 | tr -d ' \n')
    fi
    local encoded_path folder_uri
    encoded_path=$(url_encode_path "$hostpath")
    folder_uri="vscode-remote://attached-container+${hex}${encoded_path}"

    echo "Opening $display_name attached to $container..."
    "$binary" --folder-uri "$folder_uri"
}

# --- Subcommand parsing ------------------------------------------------------

CLEAN_VOLUMES=false
SSH_CONFIG_MOUNT=false

case "${1:-}" in
    -h|--help|help) show_help ;;
    ls)      MODE="ls";      shift ;;
    stop)    MODE="stop";    shift; PROJECT_FILTER=""
             # Parse --clean flag and optional project name (any order)
             for arg in "$@"; do
                 case "$arg" in
                     --clean) CLEAN_VOLUMES=true ;;
                     *)       PROJECT_FILTER="$arg" ;;
                 esac
             done
             ;;
    remove)  MODE="remove";  shift; PROJECT_FILTER="${1:-}" ;;
    port)    MODE="port";    shift; PORT_NUM="${1:-}" ;;
    ports)   MODE="ports";   shift ;;
    allow)   MODE="allow";   shift; DOMAIN="${1:-}" ;;
    deny)    MODE="deny";    shift; DOMAIN="${1:-}" ;;
    blocked)   MODE="blocked";   shift ;;
    cursor)    MODE="cursor";     shift; CURSOR_TARGET="${1:-}" ;;
    code)      MODE="code";       shift; CODE_TARGET="${1:-}" ;;
    ssh-config) MODE="ssh-config"; shift; SSH_CONFIG_ACTION="${1:-}" ;;
    clip)      MODE="clip";      shift ;;
    claude-token) MODE="claude-token"; shift ;;
    build)     MODE="build";     shift ;;
    update)    MODE="update";    shift ;;
    migrate)   MODE="migrate";   shift ;;
    migrate-naming) MODE="migrate-naming"; shift ;;
    uninstall) MODE="uninstall"; shift ;;
    prune)     MODE="prune";     shift; PRUNE_ALL=false
               [[ "${1:-}" == "--all" ]] && PRUNE_ALL=true
               ;;
    sync-skills) MODE="sync-skills"; shift ;;
    *)         MODE="auto" ;;
esac

# --- devbox ls ---------------------------------------------------------------

if [ "$MODE" = "ls" ]; then
    list_running_containers
    exit 0
fi

# --- devbox build [flags] ----------------------------------------------------

# --- devbox clip -- grab clipboard image for container use -------------------

if [ "$MODE" = "clip" ]; then
    exec "$DEVBOX_DIR/scripts/clip-image.sh"
fi

# --- devbox sync-skills -- sync host skills to all running containers --------

if [ "$MODE" = "sync-skills" ]; then
    # Obsolete: ~/.claude is now bind-mounted directly into every container
    # (see docs/adr/0002), so host-side changes to skills/ are immediately
    # visible without any sync step.
    echo "Skills are now live-shared via the host bind mount — no sync needed."
    echo "Drop new skills into ~/.claude/skills/ and they appear in every running devbox instantly."
    exit 0
fi

if [ "$MODE" = "build" ]; then
    exec "$DEVBOX_DIR/build.sh" "$@"
fi

# --- devbox claude-token -----------------------------------------------------

if [ "$MODE" = "claude-token" ]; then
    claude_token_file="$HOME/.config/devbox/claude-token"
    if ! command -v claude &>/dev/null; then
        echo "Error: 'claude' command not found. Install Claude Code first:"
        echo "  curl -fsSL https://claude.ai/install.sh | bash"
        exit 1
    fi
    if [ -f "$claude_token_file" ]; then
        printf '\033[1;33m==> Token already exists at %s. Regenerate? [y/N] \033[0m' "$claude_token_file"
        read -r answer
        if [[ ! "$answer" =~ ^[Yy]$ ]]; then
            echo "Kept existing token."
            exit 0
        fi
    fi
    mkdir -p "$HOME/.config/devbox"
    echo ""
    echo "This will open an interactive Claude setup-token session."
    echo "After authentication, the token will be printed to the screen."
    echo "Copy the token value, then paste it when prompted."
    echo ""
    echo "Press Enter to launch claude setup-token..."
    read -r
    claude setup-token
    echo ""
    printf "Paste the token value here: "
    read -r token_value
    if [ -n "$token_value" ]; then
        printf '%s\n' "$token_value" > "$claude_token_file"
        chmod 600 "$claude_token_file"
        echo "Claude token saved to $claude_token_file"
        echo "Restart your devbox containers to use the new token."
    else
        echo "No token provided. Run 'devbox claude-token' to try again."
        exit 1
    fi
    exit 0
fi

# --- devbox update -----------------------------------------------------------

if [ "$MODE" = "update" ]; then
    # Re-exec with updated script after pull (skip pull on second run)
    if [ "${DEVBOX_UPDATE_PULLED:-}" != "1" ]; then
        echo "Updating devbox..."
        pull_output=$(git -C "$DEVBOX_DIR" pull --ff-only origin main 2>&1)
        echo "$pull_output"
        if ! echo "$pull_output" | grep -q "Already up to date"; then
            echo "Re-running with updated script..."
            DEVBOX_UPDATE_PULLED=1 exec "$DEVBOX_DIR/docker-run.sh" update "$@"
        fi
    fi

    # Offer Claude token setup only if neither host OAuth credentials nor a token file exist
    claude_token_file="$HOME/.config/devbox/claude-token"
    if [ ! -f "$claude_token_file" ] \
       && [ ! -f "$HOME/.claude/.credentials.json" ] \
       && command -v claude &>/dev/null; then
        echo ""
        printf '\033[1;33m==> Claude Code token not configured. Run "devbox claude-token" to avoid daily re-login. \033[0m\n'
    fi

    if [ "${DEVBOX_UPDATE_PULLED:-}" = "1" ]; then
        # Install or refresh zsh completion file (no .zshrc modifications here)
        _completion_src="$DEVBOX_DIR/completions/_devbox"
        if [ -f "$_completion_src" ] && [ "$(basename "${SHELL:-}")" = "zsh" ]; then
            _completion_installed=false
            _fpath_dirs=$(zsh -c 'echo $fpath' 2>/dev/null | tr ' ' '\n')
            # Priority 1: writable fpath dir (no sudo)
            while IFS= read -r _dir; do
                [ -d "$_dir" ] || continue
                case "$_dir" in "$DEVBOX_DIR"*) continue ;; esac
                if [ -w "$_dir" ]; then
                    cp "$_completion_src" "$_dir/_devbox"
                    echo "Installed zsh completion in $_dir"
                    _completion_installed=true
                    break
                fi
            done <<< "$_fpath_dirs"
            # Priority 2: fpath dir via sudo -n (non-interactive, uses cached credentials)
            if [ "$_completion_installed" = false ]; then
                while IFS= read -r _dir; do
                    [ -d "$_dir" ] || continue
                    case "$_dir" in "$DEVBOX_DIR"*) continue ;; esac
                    if sudo -n cp "$_completion_src" "$_dir/_devbox" 2>/dev/null; then
                        echo "Installed zsh completion in $_dir (via sudo)"
                        _completion_installed=true
                        break
                    fi
                done <<< "$_fpath_dirs"
            fi
            if [ "$_completion_installed" = false ]; then
                echo "Note: zsh completion not updated. Run install.sh to (re)install it."
            fi
        fi
        # Auto-run migration if any old Claude volume detected. Covers both the
        # unified `devbox-claude` and per-project `devbox-<name>-claude` legacy.
        if docker volume ls --format '{{.Name}}' | grep -qE '^devbox-(.+-)?claude$'; then
            echo ""
            echo -e "\033[1;36m==> Detected pre-migration Claude volume(s) — auto-migrating to bind mount\033[0m"
            echo "    (host files preserved; container-only data merged into ~/.claude)"
            if ! "$DEVBOX_DIR/scripts/migrate-to-bindmount.sh" --auto; then
                echo -e "\033[1;31m==> Migration FAILED. Aborting update.\033[0m"
                echo "    Run 'devbox migrate' interactively to diagnose."
                exit 1
            fi
        fi
        # Auto-run LDH naming migration. `--check` exits 0 iff at least one
        # devbox container/volume carries chars the LDH-tightened sanitize
        # would now rewrite (e.g. `_`, `.`). See ADR 0005 (2026-05-06).
        if "$DEVBOX_DIR/scripts/migrate-naming-ldh.sh" --check; then
            echo ""
            echo -e "\033[1;36m==> Detected pre-LDH containers/volumes — auto-migrating names\033[0m"
            echo "    (volume data preserved; old containers removed, recreated on next devbox)"
            if ! "$DEVBOX_DIR/scripts/migrate-naming-ldh.sh" --auto; then
                echo -e "\033[1;31m==> Naming migration FAILED. Aborting update.\033[0m"
                echo "    Run 'devbox migrate-naming' interactively to diagnose."
                exit 1
            fi
        fi
        echo "Rebuilding image..."
        exec "$DEVBOX_DIR/build.sh" "$@"
    else
        echo "No changes, skipping rebuild."
    fi
    exit 0
fi

# --- devbox uninstall --------------------------------------------------------

if [ "$MODE" = "uninstall" ]; then
    exec "$DEVBOX_DIR/build.sh" --uninstall
fi

# --- devbox migrate ----------------------------------------------------------

if [ "$MODE" = "migrate" ]; then
    exec "$DEVBOX_DIR/scripts/migrate-to-bindmount.sh" "$@"
fi

if [ "$MODE" = "migrate-naming" ]; then
    exec "$DEVBOX_DIR/scripts/migrate-naming-ldh.sh" "$@"
fi

# --- devbox prune ------------------------------------------------------------

if [ "$MODE" = "prune" ]; then
    if [ "${PRUNE_ALL:-false}" = true ]; then
        echo "=== Pruning ALL Docker build cache ==="
        docker builder prune --all -f
    else
        # Calculate reserve from image size + 2GB margin
        IMAGE="vlcak/devbox:latest"
        RESERVE="10gb"
        if docker image inspect "$IMAGE" >/dev/null 2>&1; then
            SIZE_STR=$(docker images "$IMAGE" --format '{{.Size}}')
            SIZE_NUM=$(echo "$SIZE_STR" | grep -oP '^[\d.]+')
            SIZE_UNIT=$(echo "$SIZE_STR" | grep -oP '[A-Z]+$')
            if [ "$SIZE_UNIT" = "GB" ]; then
                RESERVE="$(echo "$SIZE_NUM + 2" | bc | awk '{printf "%d\n", $1 + ($1 != int($1))}')gb"
            elif [ "$SIZE_UNIT" = "MB" ]; then
                RESERVE="$(echo "$SIZE_NUM / 1024 + 2" | bc | awk '{printf "%d\n", $1 + ($1 != int($1))}')gb"
            fi
        fi
        echo "=== Pruning old Docker build cache (reserving $RESERVE) ==="
        docker buildx prune --reserved-space "$RESERVE" -f
    fi
    docker image prune -f
    exit 0
fi

# --- devbox cursor [name] ---------------------------------------------------

if [ "$MODE" = "cursor" ]; then
    attach_ide cursor "${CURSOR_TARGET:-}"
    exit 0
fi

# --- devbox code [name] ----------------------------------------------------

if [ "$MODE" = "code" ]; then
    attach_ide code "${CODE_TARGET:-}"
    exit 0
fi

# --- devbox port <port> ------------------------------------------------------

if [ "$MODE" = "port" ]; then
    if [ -z "${PORT_NUM:-}" ]; then
        echo "Usage: devbox port <port>" >&2
        exit 1
    fi

    if ! [[ "$PORT_NUM" =~ ^[0-9]+$ ]]; then
        echo "Port must be a number." >&2
        exit 1
    fi

    # Persist to default-ports.conf (deduplicated)
    ports_file="$HOME/.config/devbox/default-ports.conf"
    mkdir -p "$HOME/.config/devbox"
    touch "$ports_file"
    grep -qxF "$PORT_NUM" "$ports_file" 2>/dev/null || echo "$PORT_NUM" >> "$ports_file"

    # Apply to all running containers
    running=$(docker ps --filter "name=^devbox-" --format '{{.Names}}' | grep -v '^devbox-traefik$' || true)
    if [ -z "$running" ]; then
        echo "Port saved to default-ports.conf. No running containers."
        exit 0
    fi

    mkdir -p "$TRAEFIK_CONFIG_DIR"
    while IFS= read -r container; do
        [ -z "$container" ] && continue
        apply_port_routes "$container"
    done <<< "$running"

    # Print summary
    echo "Route added to all running containers:"
    while IFS= read -r container; do
        [ -z "$container" ] && continue
        local_project="${container#devbox-}"
        echo "  http://$(devbox::route_host "$local_project" "$PORT_NUM") → ${container}:${PORT_NUM}"
    done <<< "$running"
    exit 0
fi

# --- devbox ports ------------------------------------------------------------

if [ "$MODE" = "ports" ]; then
    if [ ! -d "$TRAEFIK_CONFIG_DIR" ] || [ -z "$(ls -A "$TRAEFIK_CONFIG_DIR" 2>/dev/null)" ]; then
        echo "No active port routes."
        exit 0
    fi

    printf '%-55s %s\n' "URL" "TARGET"
    for f in "$TRAEFIK_CONFIG_DIR"/*.yml; do
        [ -f "$f" ] || continue
        # Parse host rule and target URL from YAML
        # shellcheck disable=SC2016
        host=$(grep -oP 'Host\(`\K[^`]+' "$f" 2>/dev/null || true)
        target=$(grep -oP 'url: "\K[^"]+' "$f" 2>/dev/null || true)
        if [ -n "$host" ] && [ -n "$target" ]; then
            printf '%-55s %s\n' "http://${host}" "$target"
        fi
    done
    exit 0
fi

# --- devbox stop [nazev] -----------------------------------------------------

if [ "$MODE" = "stop" ]; then
    remove_project_volumes() {
        local proj="$1"
        for suffix in "${DEVBOX_PROJECT_VOLUME_SUFFIXES[@]}"; do
            docker volume rm "$(devbox::volume_name "$proj" "$suffix")" > /dev/null 2>&1 || true
        done
    }

    if [ -n "$PROJECT_FILTER" ]; then
        devbox::names_from_token "$PROJECT_FILTER"
        name="$DEVBOX_CONTAINER_NAME"
        if docker ps -a --filter "name=^${name}$" --format '{{.ID}}' | grep -q .; then
            graceful_stop_container "$name"
            docker rm "$name" > /dev/null
            if [ "$CLEAN_VOLUMES" = true ]; then
                remove_project_volumes "$DEVBOX_PROJECT_NAME"
                echo "Stopped + data removed:$name"
            else
                echo "Stopped:$name"
            fi
            rm -f "$TRAEFIK_CONFIG_DIR/${name}"*.yml 2>/dev/null
            stop_traefik_if_idle
            exit 0
        fi
        echo "Container $name is not running." >&2
    fi
    # No argument or container not found → interactive selection
    selected=$(pick_container "Stop container: " "with_all") || exit 1
    if [ "$selected" = "* Stop all" ]; then
        docker ps -a --filter "name=^devbox-" --format '{{.Names}}' | { grep -v '^devbox-traefik$' || true; } | while IFS= read -r c; do
            proj="${c#devbox-}"
            graceful_stop_container "$c"
            docker rm "$c" > /dev/null
            if [ "$CLEAN_VOLUMES" = true ]; then
                remove_project_volumes "$proj"
                echo "Stopped + data removed:$c"
            else
                echo "Stopped:$c"
            fi
            rm -f "$TRAEFIK_CONFIG_DIR/${c}"*.yml 2>/dev/null
        done
        stop_traefik_if_idle
    else
        proj="${selected#devbox-}"
        graceful_stop_container "$selected"
        docker rm "$selected" > /dev/null
        if [ "$CLEAN_VOLUMES" = true ]; then
            remove_project_volumes "$proj"
            echo "Stopped + data removed: $selected"
        else
            echo "Stopped: $selected"
        fi
        rm -f "$TRAEFIK_CONFIG_DIR/${selected}"*.yml 2>/dev/null
        stop_traefik_if_idle
    fi
    exit 0
fi

# --- devbox remove [nazev] ----------------------------------------------------

if [ "$MODE" = "remove" ]; then
    is_project_running() {
        docker ps --filter "name=^devbox-${1}$" --format '{{.ID}}' | grep -q .
    }

    remove_project_data() {
        local proj="$1"
        local found=false
        for suffix in "${DEVBOX_PROJECT_VOLUME_SUFFIXES[@]}"; do
            local vol
            vol="$(devbox::volume_name "$proj" "$suffix")"
            if docker volume inspect "$vol" > /dev/null 2>&1; then
                docker volume rm "$vol" > /dev/null
                echo "  Removed volume: $vol"
                found=true
            fi
        done
        if [ "$found" = false ]; then
            echo "  No volumes for project $proj." >&2
            return 1
        fi
    }

    # Find projects that have per-project volumes. The suffix-strip sed mirrors
    # DEVBOX_PROJECT_VOLUME_SUFFIXES — keep them in sync if a suffix is added.
    list_projects_with_volumes() {
        docker volume ls -q --filter "name=devbox-" 2>/dev/null \
            | grep -E -- "$(devbox::project_volume_regex)" \
            | sed 's/^devbox-//;s/-\(docker\|history\)$//' \
            | sort -u || true
    }

    if [ -n "$PROJECT_FILTER" ]; then
        # Legacy un-sanitized volumes (created before sanitize-end-to-end)
        # remain reachable: prefer the literal token when a matching volume
        # exists, otherwise use the sanitized form for the current convention.
        target="$PROJECT_FILTER"
        legacy_match=false
        for suffix in "${DEVBOX_PROJECT_VOLUME_SUFFIXES[@]}"; do
            if docker volume inspect "devbox-${PROJECT_FILTER}-${suffix}" >/dev/null 2>&1; then
                legacy_match=true
                break
            fi
        done
        if [ "$legacy_match" = false ]; then
            devbox::names_from_token "$PROJECT_FILTER"
            target="$DEVBOX_PROJECT_NAME"
        fi

        if is_project_running "$target"; then
            echo "Container devbox-${target} is running — stop it first." >&2
            exit 1
        fi
        echo "Removing data for project: $target"
        remove_project_data "$target"
        exit $?
    fi

    # Interactive: list projects with volumes
    projects=$(list_projects_with_volumes)
    if [ -z "$projects" ]; then
        echo "No devbox project volumes."
        exit 0
    fi

    selected=$(printf '%s\n' "$projects" \
        | picker::one --prompt "Remove project:" --first-option "* Remove all") || exit 1

    if [ "$selected" = "* Remove all" ]; then
        while IFS= read -r proj; do
            if is_project_running "$proj"; then
                echo "Container devbox-${proj} is running — skipping." >&2
                continue
            fi
            echo "Removing data for project: $proj"
            remove_project_data "$proj" || true
        done <<< "$projects"
    else
        if is_project_running "$selected"; then
            echo "Container devbox-${selected} is running — stop it first." >&2
            exit 1
        fi
        echo "Removing data for project: $selected"
        remove_project_data "$selected"
    fi
    exit 0
fi

# --- devbox blocked -----------------------------------------------------------

if [ "$MODE" = "blocked" ]; then
    containers=$(docker ps --filter "name=^devbox-" --format '{{.Names}}' | grep -v '^devbox-traefik$' || true)
    if [ -z "$containers" ]; then
        echo "No running devbox containers."
        exit 0
    fi

    # Collect queried domains from dnsmasq logs across all containers
    # then filter out domains that are already allowed (have ipset rules)
    all_queried=""
    while IFS= read -r container; do
        queried=$(docker exec -u root "$container" bash -c '
            [ -f /var/log/dnsmasq-queries.log ] || exit 0
            grep "^.*query\[A\]" /var/log/dnsmasq-queries.log \
                | grep -oP "query\[A\] \K[^ ]+" \
                | sort -u
        ' 2>/dev/null || true)
        [ -n "$queried" ] && all_queried=$(printf '%s\n%s' "$all_queried" "$queried")
    done <<< "$containers"
    all_queried=$(echo "$all_queried" | grep -v '^$' | sort -u)

    if [ -z "$all_queried" ]; then
        echo "No DNS queries in the log."
        exit 0
    fi

    # Get list of allowed domains from dnsmasq ipset config (inside first container)
    first_container=$(echo "$containers" | head -1)
    allowed_domains=$(docker exec -u node "$first_container" bash -c '
        grep "^ipset=" /etc/dnsmasq.d/*.conf 2>/dev/null \
            | grep -oP "ipset=/\K[^/]+" \
            | sort -u
    ' 2>/dev/null || true)

    # Filter: show only domains NOT covered by allowed list
    blocked=""
    while IFS= read -r domain; do
        [ -z "$domain" ] && continue
        is_allowed=false
        while IFS= read -r allowed; do
            [ -z "$allowed" ] && continue
            # Check exact match or subdomain match (queried is *.allowed)
            if [ "$domain" = "$allowed" ] || [[ "$domain" == *."$allowed" ]]; then
                is_allowed=true
                break
            fi
        done <<< "$allowed_domains"
        if [ "$is_allowed" = false ]; then
            blocked=$(printf '%s\n%s' "$blocked" "$domain")
        fi
    done <<< "$all_queried"
    blocked=$(echo "$blocked" | grep -v '^$' | sort -u)

    if [ -z "$blocked" ]; then
        echo "No blocked domains."
        exit 0
    fi

    declare -a domains=()
    while IFS= read -r d; do
        [ -z "$d" ] && continue
        domains+=("$d")
    done <<< "$blocked"

    selected=$(printf '%s\n' "${domains[@]}" \
        | picker::many --prompt "Allow domain:" --first-option "* Allow all") || exit 1

    while IFS= read -r sel; do
        if [ "$sel" = "* Allow all" ]; then
            for d in "${domains[@]}"; do
                "$0" allow "$d"
            done
        else
            "$0" allow "$sel"
        fi
    done <<< "$selected"
    exit 0
fi

# --- devbox allow <domain> ----------------------------------------------------

if [ "$MODE" = "allow" ]; then
    # No domain specified → list allowed domains
    if [ -z "${DOMAIN:-}" ]; then
        echo "Allowed domains (~/.config/devbox/allowed-domains.conf):"
        allowed_list=$(allowlist::read "$ALLOWLIST_HOST_FILE" | sort)
        if [ -n "$allowed_list" ]; then
            echo "$allowed_list" | while read -r d; do echo "  $d"; done
        else
            echo "  (none)"
        fi
        echo ""
        echo "Usage: devbox allow <domain>  |  devbox deny <domain>"
        echo "Note: An entry matches the domain and all of its subdomains."
        exit 0
    fi

    if allowlist::add "$ALLOWLIST_HOST_FILE" "$DOMAIN"; then
        echo "Allowed: $DOMAIN (and all subdomains)"
    else
        echo "Already allowed: $DOMAIN"
    fi

    reload_firewall_in_containers allow "$DOMAIN"
    exit 0
fi

# --- devbox deny [domain] ----------------------------------------------------

if [ "$MODE" = "deny" ]; then
    if [ ! -f "$ALLOWLIST_HOST_FILE" ] || [ -z "$(allowlist::read "$ALLOWLIST_HOST_FILE")" ]; then
        echo "No domains to remove."
        exit 0
    fi

    DENIED=""

    if [ -z "${DOMAIN:-}" ]; then
        runtime=$(allowlist::read "$ALLOWLIST_HOST_FILE" | sort)
        selected=$(printf '%s\n' "$runtime" \
            | picker::many --prompt "Remove domain:") || exit 1

        while IFS= read -r sel; do
            [ -z "$sel" ] && continue
            if allowlist::remove "$ALLOWLIST_HOST_FILE" "$sel"; then
                echo "Removed: $sel"
                DENIED+="$sel "
            fi
        done <<< "$selected"
    else
        if allowlist::remove "$ALLOWLIST_HOST_FILE" "$DOMAIN"; then
            echo "Removed: $DOMAIN"
            DENIED="$DOMAIN"
        else
            echo "Domain $DOMAIN is not in the list." >&2
            exit 1
        fi
    fi

    reload_firewall_in_containers deny "$DENIED"
    exit 0
fi

# --- devbox ssh-config [add|edit] ---------------------------------------------

if [ "$MODE" = "ssh-config" ]; then
    SSH_CONFIG_FILE="$HOME/.config/devbox/ssh_config"
    mkdir -p "$HOME/.config/devbox"

    case "${SSH_CONFIG_ACTION:-}" in
        add)
            printf "Host alias (e.g. rep): "
            read -r host_alias
            [ -z "$host_alias" ] && { echo "Host alias is required." >&2; exit 1; }

            printf "HostName (server address): "
            read -r hostname
            [ -z "$hostname" ] && { echo "HostName is required." >&2; exit 1; }

            printf "Port (default 22): "
            read -r port
            port="${port:-22}"

            printf "User (optional): "
            read -r ssh_user

            {
                echo ""
                echo "Host $host_alias"
                echo "    HostName $hostname"
                [ "$port" != "22" ] && echo "    Port $port"
                [ -n "$ssh_user" ] && echo "    User $ssh_user"
            } >> "$SSH_CONFIG_FILE"

            echo "Added to $SSH_CONFIG_FILE:"
            echo "  Host $host_alias → $hostname${port:+ :$port}"
            ;;
        edit)
            if [ ! -f "$SSH_CONFIG_FILE" ]; then
                touch "$SSH_CONFIG_FILE"
            fi
            "${EDITOR:-vi}" "$SSH_CONFIG_FILE"
            ;;
        *)
            # No action → show current config
            if [ -f "$SSH_CONFIG_FILE" ] && [ -s "$SSH_CONFIG_FILE" ]; then
                echo "Devbox SSH config (~/.config/devbox/ssh_config):"
                echo ""
                cat "$SSH_CONFIG_FILE"
            else
                echo "Devbox SSH config is empty."
            fi
            echo ""
            echo "Usage:"
            echo "  devbox ssh-config          Show config"
            echo "  devbox ssh-config add      Add a host interactively"
            echo "  devbox ssh-config edit     Open in \$EDITOR"
            ;;
    esac
    exit 0
fi

# --- Auto mode: create or attach ---------------------------------------------

# Parse optional flags before path
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --ssh-config) SSH_CONFIG_MOUNT=true; shift ;;
        *) echo "Unknown flag: $1" >&2; exit 1 ;;
    esac
done

if [ -d "${1:-.}" ]; then
    # Argument is a directory (or none → CWD) → create/attach mode
    PROJECT_PATH="$(realpath "${1:-.}")"
    devbox::names_from_path "$PROJECT_PATH"
    PROJECT_NAME="$DEVBOX_PROJECT_NAME"
    CONTAINER_NAME="$DEVBOX_CONTAINER_NAME"

    # Warn about legacy (un-sanitized) containers/volumes from an earlier
    # devbox layout — including the post-LDH break-fix where old names contain
    # `_` or `.`. Reverse derivation never matched these, so `devbox
    # reset/remove` couldn't find them. Safety-net for users who don't run
    # `devbox update`; the active migration there handles them.
    if [ "$DEVBOX_PROJECT_NAME_RAW" != "$DEVBOX_PROJECT_NAME" ]; then
        legacy_container="devbox-${DEVBOX_PROJECT_NAME_RAW}"
        if docker ps -a --filter "name=^${legacy_container}$" --format '{{.ID}}' | grep -q .; then
            echo "WARNING: legacy container '${legacy_container}' found — run 'devbox migrate-naming' or remove with:" >&2
            echo "  docker stop '${legacy_container}' && docker rm '${legacy_container}'" >&2
        fi
        for suffix in "${DEVBOX_PROJECT_VOLUME_SUFFIXES[@]}"; do
            legacy_vol="devbox-${DEVBOX_PROJECT_NAME_RAW}-${suffix}"
            if docker volume inspect "$legacy_vol" >/dev/null 2>&1; then
                echo "WARNING: legacy volume '${legacy_vol}' found — run 'devbox migrate-naming' or remove with: docker volume rm '${legacy_vol}'" >&2
            fi
        done
    fi

    if docker ps --filter "name=^${CONTAINER_NAME}$" --format '{{.ID}}' | grep -q .; then
        if [ "$SSH_CONFIG_MOUNT" = true ]; then
            echo "WARNING: --ssh-config ignored — container is already running."
            echo "  To change mounts: devbox stop && devbox --ssh-config"
        fi
        attach_to_container "$CONTAINER_NAME"
        # exec → script ends here
    fi

    # If container exists but is exited, restart it
    if docker ps -a --filter "name=^${CONTAINER_NAME}$" --filter "status=exited" --format '{{.ID}}' | grep -q .; then
        bootstrap_traefik
        if restart_exited_container "$CONTAINER_NAME"; then
            attach_to_container "$CONTAINER_NAME"
            # exec → script ends here
        fi
        # restart failed → container removed, fall through to creation
    fi

    # Container not running → create new one (detached) below
else
    # Argument is not a directory → attach by name (idempotent sanitize)
    devbox::names_from_token "$1"
    CONTAINER_NAME="$DEVBOX_CONTAINER_NAME"
    if docker ps --filter "name=^${CONTAINER_NAME}$" --format '{{.ID}}' | grep -q .; then
        attach_to_container "$CONTAINER_NAME"
    elif docker ps -a --filter "name=^${CONTAINER_NAME}$" --filter "status=exited" --format '{{.ID}}' | grep -q .; then
        bootstrap_traefik
        if restart_exited_container "$CONTAINER_NAME"; then
            attach_to_container "$CONTAINER_NAME"
        else
            echo "Container $CONTAINER_NAME removed. Run again to create a new one." >&2
            exit 1
        fi
    else
        echo "Container $CONTAINER_NAME is not running." >&2
        selected=$(pick_container "Pick a container: ") || exit 1
        attach_to_container "$selected"
    fi
fi

# --- SSH agent setup (only when creating a new container) --------------------

# SSH agent recovery - try to restore agent before giving up
if [ -z "${SSH_AUTH_SOCK:-}" ]; then
    # Try keychain's saved agent info
    keychain_sh="$HOME/.keychain/$(hostname)-sh"
    if [ -f "$keychain_sh" ]; then
        # shellcheck disable=SC1090
        . "$keychain_sh"
    fi
fi

# Verify agent is alive (socket path set but socket is dead)
if [ -n "${SSH_AUTH_SOCK:-}" ] && [ ! -S "$SSH_AUTH_SOCK" ]; then
    unset SSH_AUTH_SOCK
fi

# If still no agent, try to start one via keychain
if [ -z "${SSH_AUTH_SOCK:-}" ] && command -v keychain &>/dev/null; then
    eval "$(keychain --eval --quiet --agents ssh)"
fi

# Final fallback: start plain ssh-agent
if [ -z "${SSH_AUTH_SOCK:-}" ]; then
    echo "Starting SSH agent..."
    eval "$(ssh-agent -s)" > /dev/null
    echo "  Add your keys with: ssh-add"
fi

# Try to load default keys (non-fatal — devbox works without SSH keys)
if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
    if ! ssh-add -l &>/dev/null; then
        echo "SSH agent has no keys, trying to add default keys..."
        ssh-add 2>/dev/null || echo "  No SSH keys found — SSH forwarding will have no keys. Add keys with: ssh-add"
    fi
fi

# --- Bootstrap Traefik & devproxy network -----------------------------------

bootstrap_traefik

# --- Build docker arguments -------------------------------------------------

DOCKER_ARGS=(
    --hostname "$DEVBOX_HOSTNAME"
    --network devproxy
    # Entrypoint needs root to set up firewall + symlinks, then drops to node
    # via runuser. See scripts/devbox-entrypoint.sh and docs/adr/0003.
    --user 0
    --cap-add=SYS_ADMIN
    --cap-add=NET_ADMIN
    --cap-add=NET_RAW
    --security-opt seccomp=unconfined
    --security-opt apparmor=unconfined
    --security-opt systempaths=unconfined
    --device=/dev/net/tun
    --device=/dev/fuse
    # Per-project volumes
    -v "${DEVBOX_VOL_HISTORY}:/home/node/.local/share/atuin"
    -v "${DEVBOX_VOL_DOCKER}:/home/node/.local/share/docker"
    # Shared volumes
    -v devbox-nvim-data:/home/node/.local/share/nvim
    -v devbox-npm-global:/usr/local/share/npm-global
    -v devbox-cursor-server:/home/node/.cursor-server
    -v devbox-vscode-server:/home/node/.vscode-server
    -e CLAUDE_CONFIG_DIR=/home/node/.claude
    -e "DEVBOX_PROJECT_NAME=$DEVBOX_PROJECT_NAME"
)

# Git config from host (staging path — copied to /etc/gitconfig by entrypoint
# so VS Code/Cursor can write credential helpers without "Device busy" error)
[ -f "$HOME/.gitconfig" ] && DOCKER_ARGS+=(-v "$HOME/.gitconfig:/home/node/.gitconfig-host:ro")

# Global gitignore from host
GIT_GLOBAL_IGNORE="$HOME/.config/git/ignore"
[ -f "$GIT_GLOBAL_IGNORE" ] && DOCKER_ARGS+=(-v "$GIT_GLOBAL_IGNORE:/home/node/.config/git/ignore:ro")

# Host ~/.claude directory (RW bind mount; full sharing — see docs/adr/0002)
mkdir -p "$HOME/.claude"
DOCKER_ARGS+=(-v "$HOME/.claude:/home/node/.claude")

# Host ~/.agents directory (RO; targets of ~/.claude/skills symlinks)
[ -d "$HOME/.agents" ] && DOCKER_ARGS+=(-v "$HOME/.agents:/home/node/.agents:ro")

# Host claude binaries (RO; share host-installed Claude Code with all containers).
# Falls back to image-baked version if host has no Claude installed.
[ -d "$HOME/.local/share/claude" ] && DOCKER_ARGS+=(-v "$HOME/.local/share/claude:/home/node/.local/share/claude:ro")

# Host ~/.codex directory (RW; Codex CLI auth + config shared with host)
mkdir -p "$HOME/.codex"
DOCKER_ARGS+=(-v "$HOME/.codex:/home/node/.codex")

# SSH config: --ssh-config uses full host config, otherwise devbox-specific config
DEVBOX_SSH_CONFIG="$HOME/.config/devbox/ssh_config"
if [ "$SSH_CONFIG_MOUNT" = true ]; then
    [ -f "$HOME/.ssh/config" ] && DOCKER_ARGS+=(-v "$HOME/.ssh/config:/home/node/.ssh/config:ro")
    [ -f "$HOME/.ssh/known_hosts" ] && DOCKER_ARGS+=(-v "$HOME/.ssh/known_hosts:/home/node/.ssh/known_hosts:ro")
elif [ -f "$DEVBOX_SSH_CONFIG" ]; then
    DOCKER_ARGS+=(-v "$DEVBOX_SSH_CONFIG:/home/node/.ssh/config:ro")
fi

# SSH agent forwarding (private keys never enter the container)
if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
    DOCKER_ARGS+=(
        -v "$SSH_AUTH_SOCK:/tmp/ssh-agent.sock"
        -e SSH_AUTH_SOCK=/tmp/ssh-agent.sock
    )
else
    SSH_WARNING="WARNING: SSH agent not available - SSH forwarding won't work inside devbox
  Ensure keychain or ssh-agent is running, then restart devbox"
fi

# Pass through API key
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    DOCKER_ARGS+=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
fi

# Read Claude setup-token from config file (fallback when host has no OAuth credentials)
CLAUDE_TOKEN_FILE="$HOME/.config/devbox/claude-token"
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -f "$CLAUDE_TOKEN_FILE" ]; then
    CLAUDE_CODE_OAUTH_TOKEN="$(cat "$CLAUDE_TOKEN_FILE")"
fi
# Only pass token when host credentials are not available — symlinked OAuth takes precedence
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ ! -f "$HOME/.claude/.credentials.json" ]; then
    DOCKER_ARGS+=(-e "CLAUDE_CODE_OAUTH_TOKEN=$CLAUDE_CODE_OAUTH_TOKEN")
fi

# Auto-detect NTFY_TOKEN from host's Claude hooks if not set
if [ -z "${NTFY_TOKEN:-}" ] && [ -d "$HOME/.claude/hooks" ]; then
    NTFY_TOKEN=$(grep -ohm1 'TOKEN="tk_[^"]*"' "$HOME/.claude/hooks/"*.sh 2>/dev/null | head -1 | cut -d'"' -f2 || true)
fi

if [ -n "${NTFY_TOKEN:-}" ]; then
    DOCKER_ARGS+=(-e "NTFY_TOKEN=$NTFY_TOKEN")
fi

# Auto-detect NTFY_URL from host's Claude hooks if not set
if [ -z "${NTFY_URL:-}" ] && [ -d "$HOME/.claude/hooks" ]; then
    NTFY_URL=$(grep -ohm1 'NTFY_URL="https://[^"]*"' "$HOME/.claude/hooks/"*.sh 2>/dev/null | head -1 | cut -d'"' -f2 || true)
fi

if [ -n "${NTFY_URL:-}" ]; then
    DOCKER_ARGS+=(-e "NTFY_URL=$NTFY_URL")
fi

# Chezmoi dotfiles repo (set your own or leave empty to skip)
CHEZMOI_REPO="${CHEZMOI_REPO:-github.com/IVIJL/vlci-dotfiles}"
if [ -n "$CHEZMOI_REPO" ]; then
    DOCKER_ARGS+=(-e "CHEZMOI_REPO=$CHEZMOI_REPO")
fi

# Host home directory for WezTerm OSC 7 safe fallback CWD
DOCKER_ARGS+=(-e "HOST_HOME=$HOME")

# Shared firewall allowlist (host → all containers, read-only)
mkdir -p "$ALLOWLIST_HOST_DIR"
touch "$ALLOWLIST_HOST_FILE"
DOCKER_ARGS+=(-v "$ALLOWLIST_HOST_FILE:$ALLOWLIST_CONTAINER_FILE:ro")

# Clipboard images shared directory (host → container, same ~/.clipboard-images path)
CLIPBOARD_DIR="$HOME/.clipboard-images"
mkdir -p "$CLIPBOARD_DIR"
DOCKER_ARGS+=(-v "$CLIPBOARD_DIR:/home/node/.clipboard-images")

# Mount workspace at the host's absolute path. The entrypoint creates
# $HOST_HOME as a real directory mirroring /home/node, so binding under it
# produces a real subdir whose canonical path (getcwd(2)) matches the host
# path — which is what plugin/session parity hinges on (see docs/adr/0004).
DOCKER_ARGS+=(-v "$PROJECT_PATH:$PROJECT_PATH")
DOCKER_ARGS+=(-e "DEVBOX_PROJECT_HOST_PATH=$PROJECT_PATH")

# --- Start detached container ------------------------------------------------

# Check that image exists locally
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "Image $IMAGE not found. Build it with: devbox build" >&2
    exit 1
fi

# Print warnings just before starting container (so they're visible)
if [ -n "$SSH_WARNING" ]; then
    echo "$SSH_WARNING"
fi

# Hard gate: refuse to start if any pre-migration Claude volume exists. Catches
# the unified `devbox-claude` and any per-project `devbox-<name>-claude` from
# the older layout (commit d364a16). Both must be merged into ~/.claude before
# the bind-mount layout is safe to use.
mapfile -t stale_volumes < <(docker volume ls --format '{{.Name}}' | grep -E '^devbox-(.+-)?claude$' || true)
if [ ${#stale_volumes[@]} -gt 0 ]; then
    echo
    echo -e "\033[1;31m==> MIGRATION REQUIRED <==\033[0m"
    echo "    Pre-migration volume(s) detected: ${stale_volumes[*]}"
    echo "    The container layout has changed (see docs/adr/0002)."
    echo
    printf "    Run \033[1;36mdevbox update\033[0m to migrate automatically (recommended),\n"
    printf "    or \033[1;36mdevbox migrate\033[0m to run the migration interactively.\n"
    exit 1
fi

# Auto-cleanup obsolete devbox-claude-bin volume (claude binaries now bind-mounted
# from host ~/.local/share/claude). Safe: docker refuses removal if any container
# still references it, in which case we leave it for the next run.
if docker volume inspect "devbox-claude-bin" >/dev/null 2>&1; then
    if docker volume rm "devbox-claude-bin" >/dev/null 2>&1; then
        echo "Removed obsolete 'devbox-claude-bin' volume (claude now bind-mounted from host)"
    fi
fi

# Auto-cleanup obsolete devbox-codex-bin volume (Codex CLI moved to
# devbox-npm-global). Safe: docker refuses removal if any container still
# references it, in which case we leave it for the next run.
if docker volume inspect "devbox-codex-bin" >/dev/null 2>&1; then
    if docker volume rm "devbox-codex-bin" >/dev/null 2>&1; then
        echo "Removed obsolete 'devbox-codex-bin' volume (Codex now lives in devbox-npm-global)"
    fi
fi

echo "Mounting project: $PROJECT_PATH ($CONTAINER_NAME)"
echo "Starting devbox..."

# Start container in background
docker run -d --name "$CONTAINER_NAME" --stop-timeout 45 "${DOCKER_ARGS[@]}" "$IMAGE" devbox-entrypoint.sh

# Apply default port routes
apply_port_routes "$CONTAINER_NAME"

# Show URL info
ports_file="$HOME/.config/devbox/default-ports.conf"
if [ -f "$ports_file" ] && [ -s "$ports_file" ]; then
    echo "Port routes:"
    while read -r port _rest; do
        port="${port%%#*}"
        [ -z "$port" ] && continue
        echo "  http://$(devbox::route_host "$PROJECT_NAME" "$port") → ${CONTAINER_NAME}:${port}"
    done < "$ports_file"
else
    echo "  Set port: devbox port <port>"
fi

# Root-context setup (firewall, gitconfig, host-home symlink, IDE server
# ownership) is handled by the entrypoint on every container start.
docker exec -u node "$CONTAINER_NAME" bash -c \
    '/usr/local/bin/start-rootless-docker.sh && /usr/local/bin/setup-chezmoi.sh && /usr/local/bin/setup-claude.sh'

# Attach first interactive session
set_tab_title "$PROJECT_NAME"
exec docker exec -it -u node -w "$PROJECT_PATH" "$CONTAINER_NAME" zsh
