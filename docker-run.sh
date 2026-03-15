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
  devbox uninstall                 Remove everything (containers, volumes, image)
  devbox claude-token              Generate/regenerate Claude Code token
  devbox allow [domain]            List or add allowed firewall domain
  devbox deny [domain]             Remove allowed domain (interactive)
  devbox blocked                   Show blocked DNS queries, allow interactively
  devbox cursor [name]             Open Cursor attached to running devbox
  devbox code [name]               Open VS Code attached to running devbox
  devbox clip                      Grab clipboard image for container use
  devbox ssh-config [add|edit]     Manage devbox SSH config

Build flags:
  devbox build                     Build image (uses cache)
  devbox build --no-cache          Full rebuild without cache
  devbox build --clean             Full reset (volumes + cache) + rebuild
  devbox build --progress=plain    Show full build log

Examples:
  devbox                           Mount CWD as /workspace
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
  devbox allow pypi.org            Allow pypi.org through firewall
  devbox deny                      Interactive domain removal
  devbox blocked                   See blocked queries, allow with fzf
EOF
    exit 0
}

IMAGE="vlcak/devbox:latest"
SSH_WARNING=""
DEVBOX_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
TRAEFIK_CONFIG_DIR="$HOME/.config/devbox/traefik/dynamic"

# Migrate from old ~/.devbox to ~/.config/devbox
if [ -d "$HOME/.devbox" ] && [ ! -d "$HOME/.config/devbox" ]; then
    echo "Migrating config: ~/.devbox → ~/.config/devbox"
    mkdir -p "$HOME/.config"
    mv "$HOME/.devbox" "$HOME/.config/devbox"
fi

# --- Helper functions --------------------------------------------------------

sanitize() {
    echo "$1" | tr -cs 'a-zA-Z0-9_.-' '-' | sed 's/^-//;s/-$//'
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
    local domains_file="$HOME/.config/devbox/allowed-domains.conf"
    mkdir -p "$HOME/.config/devbox"

    local defaults
    defaults=$(cat <<'DOMAINS'
# Devbox allowed domains — edit freely, one domain per line
# Claude Code
api.anthropic.com
platform.claude.com
claude.ai
sentry.io
statsig.anthropic.com
statsig.com
mcp-proxy.anthropic.com
# npm
registry.npmjs.org
# PyPI
pypi.org
files.pythonhosted.org
# Rust crates
crates.io
static.crates.io
# VS Code / Cursor
marketplace.visualstudio.com
vscode.blob.core.windows.net
update.code.visualstudio.com
*.vscode-cdn.net
*.vsassets.io
cursor.com
cursor.sh
raw.githubusercontent.com
# Docker Hub (rootless DinD)
registry-1.docker.io
auth.docker.io
production.cloudflare.docker.com
docker.io
docker-images-prod.6aa30f8b08e16409b46e0173d6de2f56.r2.cloudflarestorage.com
# Custom
gaiagroup.cz
DOMAINS
)

    if [ ! -f "$domains_file" ]; then
        echo "$defaults" > "$domains_file"
    elif ! grep -q '^# Devbox allowed domains' "$domains_file" 2>/dev/null; then
        # Migration: old file without defaults — prepend defaults, keep user entries
        local user_entries
        user_entries=$(grep -v '^\s*#' "$domains_file" 2>/dev/null | grep -v '^\s*$' || true)
        echo "$defaults" > "$domains_file"
        if [ -n "$user_entries" ]; then
            echo "" >> "$domains_file"
            echo "# User-added" >> "$domains_file"
            while IFS= read -r entry; do
                grep -qxF "$entry" "$domains_file" 2>/dev/null || echo "$entry" >> "$domains_file"
            done <<< "$user_entries"
        fi
    fi

    # Migration: add VS Code CDN domains if missing from existing config
    if [ -f "$domains_file" ]; then
        for d in "*.vscode-cdn.net" "*.vsassets.io"; do
            grep -qF "$d" "$domains_file" 2>/dev/null || echo "$d" >> "$domains_file"
        done
    fi
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

        local host_rule="${port}.${project}.127.0.0.1.traefik.me"
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
    docker exec "$name" bash -c '
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
        echo "Zastaven: devbox-traefik (žádné zbývající kontejnery)"
    fi
}

attach_to_container() {
    local name="$1"
    echo "Attaching to running container: $name"
    set_tab_title "${name#devbox-}"
    exec docker exec -it -w /workspace "$name" zsh
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
    # Re-run init scripts (firewall, rootless docker, chezmoi, claude)
    docker exec -u root "$name" bash -c 'cp /home/node/.gitconfig-host /etc/gitconfig 2>/dev/null; /usr/local/bin/init-firewall.sh'
    docker exec "$name" bash -c \
        '/usr/local/bin/start-rootless-docker.sh && /usr/local/bin/setup-chezmoi.sh && /usr/local/bin/setup-claude.sh'
    # Re-apply port routes
    apply_port_routes "$name"
}

list_running_containers() {
    local containers
    containers=$(docker ps --filter "name=^devbox-" --format '{{.Names}}\t{{.Status}}\t{{.RunningFor}}' | grep -v '^devbox-traefik\b' || true)
    if [ -z "$containers" ]; then
        echo "Žádné běžící devbox kontejnery."
    else
        printf '%-25s %-50s %s\n' "NAME" "URL" "STATUS"
        while IFS=$'\t' read -r name status running; do
            local project="${name#devbox-}"
            local url="http://<port>.${project}.127.0.0.1.traefik.me"
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

# Regenerate dnsmasq runtime config and restart in all running containers
# $1 = optional domain to resolve after restart (for allow)
# $2 = optional space-separated domains to remove from ipset (for deny)
reload_dnsmasq_in_containers() {
    local resolve_domain="${1:-}"
    local deny_domains="${2:-}"
    local containers
    containers=$(docker ps --filter "name=^devbox-" --format '{{.Names}}' | grep -v '^devbox-traefik$' || true)
    [ -z "$containers" ] && return 0
    while IFS= read -r container; do
        docker exec -u root "$container" bash -c '
            # Regenerate runtime config from shared file
            : > /etc/dnsmasq.d/devbox-runtime.conf
            if [ -f /etc/devbox-shared/allowed-domains.conf ]; then
                while IFS= read -r line; do
                    line=$(echo "$line" | sed "s/#.*//" | xargs)
                    [ -n "$line" ] && echo "ipset=/${line}/allowed-domains" >> /etc/dnsmasq.d/devbox-runtime.conf
                done < /etc/devbox-shared/allowed-domains.conf
            fi
            # Kill dnsmasq reliably
            pkill -9 dnsmasq 2>/dev/null || true
            # Wait for process to actually die
            for _i in 1 2 3 4 5; do
                pgrep -x dnsmasq >/dev/null 2>&1 || break
                sleep 0.1
            done
            rm -f /run/dnsmasq/dnsmasq.pid /var/run/dnsmasq/dnsmasq.pid 2>/dev/null
            # Start dnsmasq and verify
            if ! dnsmasq --conf-dir=/etc/dnsmasq.d 2>&1; then
                echo "ERROR: dnsmasq failed to start" >&2
                exit 1
            fi
            sleep 0.3
            if ! pgrep -x dnsmasq >/dev/null 2>&1; then
                echo "ERROR: dnsmasq not running after start" >&2
                exit 1
            fi
            # Remove denied domains IPs from ipset
            for deny_domain in '"$deny_domains"'; do
                nslookup "$deny_domain" 127.0.0.1 2>/dev/null | grep -oP "Address: \K[0-9.]+" | while read -r ip; do
                    ipset del allowed-domains "$ip" 2>/dev/null || true
                done
            done
            # Resolve new domain to populate ipset (if allow)
            if [ -n "'"$resolve_domain"'" ]; then
                nslookup "'"$resolve_domain"'" 127.0.0.1 > /dev/null 2>&1 || true
            fi
        ' && echo "  Reloaded: $container" || echo "  Failed: $container" >&2
    done <<< "$containers"
}

# Interactive container picker
# $1 = prompt text, $2 = optionally "with_all" to add "stop all" option
# Returns selected name on stdout, returns 1 on cancel/empty
pick_container() {
    local prompt="$1"
    local with_all="${2:-}"
    local running
    running=$(docker ps -a --filter "name=^devbox-" --format '{{.Names}}' | grep -v '^devbox-traefik$' || true)

    if [ -z "$running" ]; then
        echo "Žádné devbox kontejnery." >&2
        return 1
    fi

    local options="$running"
    if [ "$with_all" = "with_all" ]; then
        options=$(printf '%s\n%s' "$running" "* Zastavit všechny")
    fi

    if command -v fzf &>/dev/null; then
        echo "$options" | fzf --prompt="$prompt" || return 1
    else
        # Fallback: numbered menu
        echo "" >&2
        local i=1
        while IFS= read -r line; do
            echo "  $i) $line" >&2
            i=$((i + 1))
        done <<< "$options"
        echo "" >&2
        printf "%s" "$prompt" >&2
        read -r choice
        sed -n "${choice}p" <<< "$options"
    fi
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
    uninstall) MODE="uninstall"; shift ;;
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
    echo "Running 'claude setup-token'..."
    echo "Follow the prompts to authenticate."
    if token=$(claude setup-token 2>/dev/null); then
        printf '%s\n' "$token" > "$claude_token_file"
        chmod 600 "$claude_token_file"
        echo "Claude token saved to $claude_token_file"
        echo "Restart your devbox containers to use the new token."
    else
        echo "claude setup-token failed. Try running it manually:"
        echo "  claude setup-token > $claude_token_file"
        exit 1
    fi
    exit 0
fi

# --- devbox update -----------------------------------------------------------

if [ "$MODE" = "update" ]; then
    echo "Updating devbox..."
    pull_output=$(git -C "$DEVBOX_DIR" pull --ff-only origin main 2>&1)
    echo "$pull_output"

    # Offer Claude token setup if not configured yet
    claude_token_file="$HOME/.config/devbox/claude-token"
    if [ ! -f "$claude_token_file" ] && command -v claude &>/dev/null; then
        echo ""
        printf '\033[1;33m==> Generate Claude Code token for containers? (avoids daily re-login) [y/N] \033[0m'
        read -r answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            mkdir -p "$HOME/.config/devbox"
            echo "Running 'claude setup-token'..."
            echo "Follow the prompts to authenticate."
            if token=$(claude setup-token 2>/dev/null); then
                printf '%s\n' "$token" > "$claude_token_file"
                chmod 600 "$claude_token_file"
                echo "Claude token saved to $claude_token_file"
            else
                echo "claude setup-token failed. You can run it manually later:"
                echo "  claude setup-token > $claude_token_file"
            fi
        fi
    fi

    if echo "$pull_output" | grep -q "Already up to date"; then
        echo "No changes, skipping rebuild."
    else
        echo "Rebuilding image..."
        exec "$DEVBOX_DIR/build.sh" "$@"
    fi
    exit 0
fi

# --- devbox uninstall --------------------------------------------------------

if [ "$MODE" = "uninstall" ]; then
    exec "$DEVBOX_DIR/build.sh" --uninstall
fi

# --- devbox cursor [name] ---------------------------------------------------

if [ "$MODE" = "cursor" ]; then
    if ! command -v cursor &>/dev/null; then
        echo "Error: 'cursor' CLI not found in PATH." >&2
        echo "Install it: Cursor → Cmd+Shift+P → 'Install cursor command in PATH'" >&2
        exit 1
    fi

    # Determine target container
    if [ -n "${CURSOR_TARGET:-}" ]; then
        CONTAINER_NAME="devbox-$(sanitize "$CURSOR_TARGET")"
    else
        PROJECT_NAME="$(sanitize "$(basename "$(pwd)")")"
        CONTAINER_NAME="devbox-${PROJECT_NAME}"
    fi

    # Verify container is running
    if ! docker ps --filter "name=^${CONTAINER_NAME}$" --format '{{.Names}}' | grep -q .; then
        echo "Container $CONTAINER_NAME is not running." >&2
        # Try to pick from running containers
        selected=$(pick_container "Select container: ") || exit 1
        CONTAINER_NAME="$selected"
    fi

    # Build attached-container URI for Cursor
    # Format: vscode-remote://attached-container+<hex-encoded-json>/workspace
    ATTACH_JSON="{\"containerName\":\"/${CONTAINER_NAME}\"}"
    if command -v xxd &>/dev/null; then
        HEX=$(printf '%s' "$ATTACH_JSON" | xxd -p | tr -d '\n')
    else
        HEX=$(printf '%s' "$ATTACH_JSON" | od -A n -t x1 | tr -d ' \n')
    fi
    FOLDER_URI="vscode-remote://attached-container+${HEX}/workspace"

    echo "Opening Cursor attached to $CONTAINER_NAME..."
    cursor --folder-uri "$FOLDER_URI"
    exit 0
fi

# --- devbox code [name] ----------------------------------------------------

if [ "$MODE" = "code" ]; then
    if ! command -v code &>/dev/null; then
        echo "Error: 'code' CLI not found in PATH." >&2
        echo "Install it: VS Code → Cmd+Shift+P → 'Install code command in PATH'" >&2
        exit 1
    fi

    # Determine target container
    if [ -n "${CODE_TARGET:-}" ]; then
        CONTAINER_NAME="devbox-$(sanitize "$CODE_TARGET")"
    else
        PROJECT_NAME="$(sanitize "$(basename "$(pwd)")")"
        CONTAINER_NAME="devbox-${PROJECT_NAME}"
    fi

    # Verify container is running
    if ! docker ps --filter "name=^${CONTAINER_NAME}$" --format '{{.Names}}' | grep -q .; then
        echo "Container $CONTAINER_NAME is not running." >&2
        # Try to pick from running containers
        selected=$(pick_container "Select container: ") || exit 1
        CONTAINER_NAME="$selected"
    fi

    # Build attached-container URI for VS Code
    ATTACH_JSON="{\"containerName\":\"/${CONTAINER_NAME}\"}"
    if command -v xxd &>/dev/null; then
        HEX=$(printf '%s' "$ATTACH_JSON" | xxd -p | tr -d '\n')
    else
        HEX=$(printf '%s' "$ATTACH_JSON" | od -A n -t x1 | tr -d ' \n')
    fi
    FOLDER_URI="vscode-remote://attached-container+${HEX}/workspace"

    echo "Opening VS Code attached to $CONTAINER_NAME..."
    code --folder-uri "$FOLDER_URI"
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
        echo "Port uložen do default-ports.conf. Žádné běžící kontejnery."
        exit 0
    fi

    mkdir -p "$TRAEFIK_CONFIG_DIR"
    while IFS= read -r container; do
        [ -z "$container" ] && continue
        apply_port_routes "$container"
    done <<< "$running"

    # Print summary
    echo "Route přidána pro všechny běžící kontejnery:"
    while IFS= read -r container; do
        [ -z "$container" ] && continue
        local_project="${container#devbox-}"
        echo "  http://${PORT_NUM}.${local_project}.127.0.0.1.traefik.me → ${container}:${PORT_NUM}"
    done <<< "$running"
    exit 0
fi

# --- devbox ports ------------------------------------------------------------

if [ "$MODE" = "ports" ]; then
    if [ ! -d "$TRAEFIK_CONFIG_DIR" ] || [ -z "$(ls -A "$TRAEFIK_CONFIG_DIR" 2>/dev/null)" ]; then
        echo "Žádné aktivní port routy."
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
        for suffix in docker history; do
            docker volume rm "devbox-${proj}-${suffix}" > /dev/null 2>&1 || true
        done
    }

    if [ -n "$PROJECT_FILTER" ]; then
        name="devbox-${PROJECT_FILTER}"
        if docker ps -a --filter "name=^${name}$" --format '{{.ID}}' | grep -q .; then
            graceful_stop_container "$name"
            docker rm "$name" > /dev/null
            if [ "$CLEAN_VOLUMES" = true ]; then
                remove_project_volumes "$PROJECT_FILTER"
                echo "Zastaven + odstraněna data: $name"
            else
                echo "Zastaven: $name"
            fi
            rm -f "$TRAEFIK_CONFIG_DIR/${name}"*.yml 2>/dev/null
            stop_traefik_if_idle
            exit 0
        fi
        echo "Kontejner $name neběží." >&2
    fi
    # No argument or container not found → interactive selection
    selected=$(pick_container "Zastavit kontejner: " "with_all") || exit 1
    if [ "$selected" = "* Zastavit všechny" ]; then
        docker ps -a --filter "name=^devbox-" --format '{{.Names}}' | { grep -v '^devbox-traefik$' || true; } | while IFS= read -r c; do
            proj="${c#devbox-}"
            graceful_stop_container "$c"
            docker rm "$c" > /dev/null
            if [ "$CLEAN_VOLUMES" = true ]; then
                remove_project_volumes "$proj"
                echo "Zastaven + odstraněna data: $c"
            else
                echo "Zastaven: $c"
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
            echo "Zastaven + odstraněna data: $selected"
        else
            echo "Zastaven: $selected"
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
        for suffix in docker history; do
            local vol="devbox-${proj}-${suffix}"
            if docker volume inspect "$vol" > /dev/null 2>&1; then
                docker volume rm "$vol" > /dev/null
                echo "  Smazán volume: $vol"
                found=true
            fi
        done
        if [ "$found" = false ]; then
            echo "  Žádné volumes pro projekt $proj." >&2
            return 1
        fi
    }

    # Find projects that have per-project volumes
    list_projects_with_volumes() {
        docker volume ls -q --filter "name=devbox-" 2>/dev/null \
            | grep -E -- '^devbox-.+-(docker|history)$' \
            | sed 's/^devbox-//;s/-\(docker\|history\)$//' \
            | sort -u || true
    }

    if [ -n "$PROJECT_FILTER" ]; then
        if is_project_running "$PROJECT_FILTER"; then
            echo "Kontejner devbox-${PROJECT_FILTER} běží — nejdřív ho zastav." >&2
            exit 1
        fi
        echo "Odstraňuji data projektu: $PROJECT_FILTER"
        remove_project_data "$PROJECT_FILTER"
        exit $?
    fi

    # Interactive: list projects with volumes
    projects=$(list_projects_with_volumes)
    if [ -z "$projects" ]; then
        echo "Žádné devbox projektové volumes."
        exit 0
    fi

    options=$(printf "* Odstranit všechny\n%s" "$projects")
    if command -v fzf &>/dev/null; then
        selected=$(echo "$options" | fzf --prompt="Odstranit projekt: ") || exit 1
    else
        echo "" >&2
        echo "Projekty s volumes:" >&2
        i=1
        while IFS= read -r line; do
            echo "  $i) $line" >&2
            i=$((i + 1))
        done <<< "$options"
        echo "" >&2
        printf "Vyberte projekt k odstranění: " >&2
        read -r choice
        selected=$(sed -n "${choice}p" <<< "$options")
    fi

    if [ -z "$selected" ]; then
        echo "Neplatná volba." >&2
        exit 1
    fi

    if [ "$selected" = "* Odstranit všechny" ]; then
        while IFS= read -r proj; do
            if is_project_running "$proj"; then
                echo "Kontejner devbox-${proj} běží — přeskakuji." >&2
                continue
            fi
            echo "Odstraňuji data projektu: $proj"
            remove_project_data "$proj" || true
        done <<< "$projects"
    else
        if is_project_running "$selected"; then
            echo "Kontejner devbox-${selected} běží — nejdřív ho zastav." >&2
            exit 1
        fi
        echo "Odstraňuji data projektu: $selected"
        remove_project_data "$selected"
    fi
    exit 0
fi

# --- devbox blocked -----------------------------------------------------------

if [ "$MODE" = "blocked" ]; then
    containers=$(docker ps --filter "name=^devbox-" --format '{{.Names}}' | grep -v '^devbox-traefik$' || true)
    if [ -z "$containers" ]; then
        echo "Žádné běžící devbox kontejnery."
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
        echo "Žádné DNS dotazy v logu."
        exit 0
    fi

    # Get list of allowed domains from dnsmasq ipset config (inside first container)
    first_container=$(echo "$containers" | head -1)
    allowed_domains=$(docker exec "$first_container" bash -c '
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
        echo "Žádné blokované domény."
        exit 0
    fi

    # Build menu
    declare -a domains=()
    while IFS= read -r d; do
        [ -z "$d" ] && continue
        domains+=("$d")
    done <<< "$blocked"

    if command -v fzf &>/dev/null; then
        options=$(printf "* Povolit všechny\n%s" "$blocked")
        selected=$(echo "$options" | fzf --prompt="Povolit doménu: " --multi) || exit 1
    else
        echo "Blokované domény:"
        echo ""
        for i in "${!domains[@]}"; do
            echo "  $((i + 1))) ${domains[$i]}"
        done
        echo "  a) Povolit všechny"
        echo "  q) Zrušit"
        echo ""
        printf "Vyber (číslo/a/q): "
        read -r choice

        if [ "$choice" = "q" ]; then
            exit 0
        elif [ "$choice" = "a" ]; then
            selected="* Povolit všechny"
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#domains[@]}" ]; then
            selected="${domains[$((choice - 1))]}"
        else
            echo "Neplatná volba." >&2
            exit 1
        fi
    fi

    while IFS= read -r sel; do
        if [ "$sel" = "* Povolit všechny" ]; then
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
    CONF="$HOME/.config/devbox/allowed-domains.conf"
    mkdir -p "$HOME/.config/devbox"
    touch "$CONF"

    # No domain specified → list allowed domains
    if [ -z "${DOMAIN:-}" ]; then
        echo "Povolené domény (~/.config/devbox/allowed-domains.conf):"
        allowed_list=$(grep -v '^\s*#' "$CONF" 2>/dev/null | grep -v '^\s*$' | sort || true)
        if [ -n "$allowed_list" ]; then
            echo "$allowed_list" | while read -r d; do echo "  $d"; done
        else
            echo "  (žádné)"
        fi
        echo ""
        echo "Použití: devbox allow <domain>  |  devbox deny <domain>"
        exit 0
    fi

    # Add domain
    if grep -qxF "$DOMAIN" "$CONF" 2>/dev/null; then
        echo "Již povoleno: $DOMAIN"
    else
        echo "$DOMAIN" >> "$CONF"
        echo "Povoleno: $DOMAIN"
    fi

    reload_dnsmasq_in_containers "$DOMAIN" ""
    exit 0
fi

# --- devbox deny [domain] ----------------------------------------------------

if [ "$MODE" = "deny" ]; then
    CONF="$HOME/.config/devbox/allowed-domains.conf"

    if [ ! -f "$CONF" ] || ! grep -v '^\s*#' "$CONF" 2>/dev/null | grep -qv '^\s*$'; then
        echo "Žádné domény k odebrání."
        exit 0
    fi

    DENIED=""

    if [ -z "${DOMAIN:-}" ]; then
        # Interactive selection
        runtime=$(grep -v '^\s*#' "$CONF" | grep -v '^\s*$' | sort)
        if command -v fzf &>/dev/null; then
            selected=$(echo "$runtime" | fzf --prompt="Odebrat doménu: " --multi) || exit 1
        else
            echo "Runtime domény:"
            echo ""
            declare -a items=()
            while IFS= read -r d; do
                [ -z "$d" ] && continue
                items+=("$d")
            done <<< "$runtime"
            for i in "${!items[@]}"; do
                echo "  $((i + 1))) ${items[$i]}"
            done
            echo "  q) Zrušit"
            echo ""
            printf "Vyber (číslo/q): "
            read -r choice
            if [ "$choice" = "q" ]; then
                exit 0
            elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#items[@]}" ]; then
                selected="${items[$((choice - 1))]}"
            else
                echo "Neplatná volba." >&2
                exit 1
            fi
        fi

        while IFS= read -r sel; do
            [ -z "$sel" ] && continue
            { grep -vxF "$sel" "$CONF" || true; } > "${CONF}.tmp" && mv "${CONF}.tmp" "$CONF"
            echo "Odebráno: $sel"
            DENIED+="$sel "
        done <<< "$selected"
    else
        if grep -qxF "$DOMAIN" "$CONF" 2>/dev/null; then
            { grep -vxF "$DOMAIN" "$CONF" || true; } > "${CONF}.tmp" && mv "${CONF}.tmp" "$CONF"
            echo "Odebráno: $DOMAIN"
            DENIED="$DOMAIN"
        else
            echo "Doména $DOMAIN není v seznamu." >&2
            exit 1
        fi
    fi

    reload_dnsmasq_in_containers "" "$DENIED"
    exit 0
fi

# --- devbox ssh-config [add|edit] ---------------------------------------------

if [ "$MODE" = "ssh-config" ]; then
    SSH_CONFIG_FILE="$HOME/.config/devbox/ssh_config"
    mkdir -p "$HOME/.config/devbox"

    case "${SSH_CONFIG_ACTION:-}" in
        add)
            printf "Host alias (např. rep): "
            read -r host_alias
            [ -z "$host_alias" ] && { echo "Host alias je povinný." >&2; exit 1; }

            printf "HostName (adresa serveru): "
            read -r hostname
            [ -z "$hostname" ] && { echo "HostName je povinný." >&2; exit 1; }

            printf "Port (výchozí 22): "
            read -r port
            port="${port:-22}"

            printf "User (volitelné): "
            read -r ssh_user

            {
                echo ""
                echo "Host $host_alias"
                echo "    HostName $hostname"
                [ "$port" != "22" ] && echo "    Port $port"
                [ -n "$ssh_user" ] && echo "    User $ssh_user"
            } >> "$SSH_CONFIG_FILE"

            echo "Přidáno do $SSH_CONFIG_FILE:"
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
                echo "Devbox SSH config je prázdný."
            fi
            echo ""
            echo "Použití:"
            echo "  devbox ssh-config          Zobrazit config"
            echo "  devbox ssh-config add      Přidat host interaktivně"
            echo "  devbox ssh-config edit     Otevřít v \$EDITOR"
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
    PROJECT_NAME="$(basename "$PROJECT_PATH")"
    CONTAINER_NAME="devbox-$(sanitize "$PROJECT_NAME")"

    if docker ps --filter "name=^${CONTAINER_NAME}$" --format '{{.ID}}' | grep -q .; then
        if [ "$SSH_CONFIG_MOUNT" = true ]; then
            echo "WARNING: --ssh-config ignorován — kontejner již běží."
            echo "  Pro změnu mountů: devbox stop && devbox --ssh-config"
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
    # Argument is not a directory → attach by name
    CONTAINER_NAME="devbox-${1}"
    if docker ps --filter "name=^${CONTAINER_NAME}$" --format '{{.ID}}' | grep -q .; then
        attach_to_container "$CONTAINER_NAME"
    elif docker ps -a --filter "name=^${CONTAINER_NAME}$" --filter "status=exited" --format '{{.ID}}' | grep -q .; then
        bootstrap_traefik
        if restart_exited_container "$CONTAINER_NAME"; then
            attach_to_container "$CONTAINER_NAME"
        else
            echo "Kontejner $CONTAINER_NAME odstraněn. Spusťte znovu pro vytvoření nového." >&2
            exit 1
        fi
    else
        echo "Kontejner $CONTAINER_NAME neběží." >&2
        selected=$(pick_container "Vyber kontejner: ") || exit 1
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
    --hostname "$PROJECT_NAME"
    --network devproxy
    --cap-add=SYS_ADMIN
    --cap-add=NET_ADMIN
    --cap-add=NET_RAW
    --security-opt seccomp=unconfined
    --security-opt apparmor=unconfined
    --security-opt systempaths=unconfined
    --device=/dev/net/tun
    --device=/dev/fuse
    # Per-project volumes
    -v "devbox-${PROJECT_NAME}-history:/home/node/.local/share/atuin"
    -v "devbox-${PROJECT_NAME}-docker:/home/node/.local/share/docker"
    -v "devbox-${PROJECT_NAME}-claude:/home/node/.claude"
    # Shared volumes
    -v devbox-nvim-data:/home/node/.local/share/nvim
    -v devbox-cursor-server:/home/node/.cursor-server
    -v devbox-vscode-server:/home/node/.vscode-server
    -e CLAUDE_CONFIG_DIR=/home/node/.claude
)

# Git config from host (staging path — copied to /etc/gitconfig by entrypoint
# so VS Code/Cursor can write credential helpers without "Device busy" error)
[ -f "$HOME/.gitconfig" ] && DOCKER_ARGS+=(-v "$HOME/.gitconfig:/home/node/.gitconfig-host:ro")

# Global gitignore from host
GIT_GLOBAL_IGNORE="$HOME/.config/git/ignore"
[ -f "$GIT_GLOBAL_IGNORE" ] && DOCKER_ARGS+=(-v "$GIT_GLOBAL_IGNORE:/home/node/.config/git/ignore:ro")

# Host ~/.claude directory (read-only staging; setup-claude.sh symlinks CLAUDE.md into the volume)
[ -d "$HOME/.claude" ] && DOCKER_ARGS+=(-v "$HOME/.claude:/home/node/.host-config/claude:ro")

# Host ~/.claude.json (read-only staging; setup-claude.sh copies into container)
[ -f "$HOME/.claude.json" ] && DOCKER_ARGS+=(-v "$HOME/.claude.json:/home/node/.host-config/claude.json:ro")

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

# Read Claude setup-token from config file and pass to container
CLAUDE_TOKEN_FILE="$HOME/.config/devbox/claude-token"
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -f "$CLAUDE_TOKEN_FILE" ]; then
    CLAUDE_CODE_OAUTH_TOKEN="$(cat "$CLAUDE_TOKEN_FILE")"
fi
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    DOCKER_ARGS+=(-e "CLAUDE_CODE_OAUTH_TOKEN=$CLAUDE_CODE_OAUTH_TOKEN")
fi

# Pass through extra domains
if [ -n "${DEVBOX_EXTRA_DOMAINS:-}" ]; then
    DOCKER_ARGS+=(-e "DEVBOX_EXTRA_DOMAINS=$DEVBOX_EXTRA_DOMAINS")
fi

# Auto-detect NTFY_TOKEN from host's Claude hooks if not set
if [ -z "${NTFY_TOKEN:-}" ] && [ -d "$HOME/.claude/hooks" ]; then
    NTFY_TOKEN=$(grep -ohm1 'TOKEN="tk_[^"]*"' "$HOME/.claude/hooks/"*.sh 2>/dev/null | head -1 | cut -d'"' -f2 || true)
fi

if [ -n "${NTFY_TOKEN:-}" ]; then
    DOCKER_ARGS+=(-e "NTFY_TOKEN=$NTFY_TOKEN")
fi

# Chezmoi dotfiles repo (set your own or leave empty to skip)
CHEZMOI_REPO="${CHEZMOI_REPO:-github.com/IVIJL/vlci-dotfiles}"
if [ -n "$CHEZMOI_REPO" ]; then
    DOCKER_ARGS+=(-e "CHEZMOI_REPO=$CHEZMOI_REPO")
fi

# Host home directory for WezTerm OSC 7 safe fallback CWD
DOCKER_ARGS+=(-e "HOST_HOME=$HOME")

# Shared firewall allowlist (host → all containers, read-only)
DEVBOX_CONFIG_DIR="$HOME/.config/devbox"
mkdir -p "$DEVBOX_CONFIG_DIR"
touch "$DEVBOX_CONFIG_DIR/allowed-domains.conf"
DOCKER_ARGS+=(-v "$DEVBOX_CONFIG_DIR/allowed-domains.conf:/etc/devbox-shared/allowed-domains.conf:ro")

# Clipboard images shared directory (host → container, same ~/.clipboard-images path)
CLIPBOARD_DIR="$HOME/.clipboard-images"
mkdir -p "$CLIPBOARD_DIR"
DOCKER_ARGS+=(-v "$CLIPBOARD_DIR:/home/node/.clipboard-images")

# Mount workspace
DOCKER_ARGS+=(-v "$PROJECT_PATH:/workspace")

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

echo "Mounting project: $PROJECT_PATH -> /workspace ($CONTAINER_NAME)"
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
        echo "  http://${port}.${PROJECT_NAME}.127.0.0.1.traefik.me → ${CONTAINER_NAME}:${port}"
    done < "$ports_file"
else
    echo "  Set port: devbox port <port>"
fi

# Init scripts: firewall runs as root (no sudo needed), rest as node
# Fix IDE server directory permissions (volumes may be created as root)
docker exec -u root "$CONTAINER_NAME" bash -c \
    'cp /home/node/.gitconfig-host /etc/gitconfig 2>/dev/null; chown node:node /home/node/.cursor-server /home/node/.vscode-server 2>/dev/null; /usr/local/bin/init-firewall.sh'
docker exec "$CONTAINER_NAME" bash -c \
    '/usr/local/bin/start-rootless-docker.sh && /usr/local/bin/setup-chezmoi.sh && /usr/local/bin/setup-claude.sh'

# Attach first interactive session
set_tab_title "$PROJECT_NAME"
exec docker exec -it -w /workspace "$CONTAINER_NAME" zsh
