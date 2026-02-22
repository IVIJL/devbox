#!/bin/bash
set -euo pipefail

# =============================================================================
# Devbox - Docker run convenience script
# =============================================================================
# Usage:
#   devbox                                  # mount current directory as /workspace
#   devbox /path/to/project                 # mount project as /workspace
#   devbox nazev                            # attach to running devbox-nazev container
#   devbox ls                               # list running devbox containers
#   devbox stop <nazev>                     # stop container and remove docker volume
#   devbox port <port>                      # expose port on all containers via Traefik
#   devbox ports                            # list active port routes
#   devbox allow <domain>                   # allow domain through firewall (all containers)
#   devbox blocked                          # show blocked connections, interactively allow
#
# Install globally:
#   sudo ln -s /path/to/devbox/docker-run.sh /usr/local/bin/devbox
# =============================================================================

IMAGE="vlcak/devbox:latest"
SSH_WARNING=""
TRAEFIK_CONFIG_DIR="$HOME/.devbox/traefik/dynamic"

# --- Helper functions --------------------------------------------------------

sanitize() {
    echo "$1" | tr -cs 'a-zA-Z0-9_.-' '-' | sed 's/^-//;s/-$//'
}

bootstrap_traefik() {
    docker network inspect devproxy >/dev/null 2>&1 || docker network create devproxy

    mkdir -p "$TRAEFIK_CONFIG_DIR"
    seed_default_ports

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

seed_default_ports() {
    local ports_file="$HOME/.devbox/default-ports.conf"
    [ -f "$ports_file" ] && return 0
    mkdir -p "$HOME/.devbox"
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
8888
9000
9090
PORTS
}

apply_port_routes() {
    local container="$1"
    local project="${container#devbox-}"
    local ports_file="$HOME/.devbox/default-ports.conf"
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
    exec docker exec -it -w /workspace "$name" zsh
}

list_running_containers() {
    local containers
    containers=$(docker ps --filter "name=^devbox-" --format '{{.Names}}\t{{.Status}}\t{{.RunningFor}}' | grep -v '^devbox-traefik\b')
    if [ -z "$containers" ]; then
        echo "Žádné běžící devbox kontejnery."
        return
    fi
    printf '%-25s %-50s %s\n' "NAME" "URL" "STATUS"
    while IFS=$'\t' read -r name status running; do
        local project="${name#devbox-}"
        local url="http://<port>.${project}.127.0.0.1.traefik.me"
        printf '%-25s %-50s %s\n' "$name" "$url" "$status"
    done <<< "$containers"
}

# Interactive container picker
# $1 = prompt text, $2 = optionally "with_all" to add "stop all" option
# Returns selected name on stdout, returns 1 on cancel/empty
pick_container() {
    local prompt="$1"
    local with_all="${2:-}"
    local running
    running=$(docker ps --filter "name=^devbox-" --format '{{.Names}}' | grep -v '^devbox-traefik$')

    if [ -z "$running" ]; then
        echo "Žádné běžící devbox kontejnery." >&2
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

case "${1:-}" in
    ls)      MODE="ls";      shift ;;
    stop)    MODE="stop";    shift; PROJECT_FILTER="${1:-}" ;;
    port)    MODE="port";    shift; PORT_NUM="${1:-}" ;;
    ports)   MODE="ports";   shift ;;
    allow)   MODE="allow";   shift; DOMAIN="${1:-}" ;;
    blocked) MODE="blocked"; shift ;;
    *)       MODE="auto" ;;
esac

# --- devbox ls ---------------------------------------------------------------

if [ "$MODE" = "ls" ]; then
    list_running_containers
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
    ports_file="$HOME/.devbox/default-ports.conf"
    mkdir -p "$HOME/.devbox"
    touch "$ports_file"
    grep -qxF "$PORT_NUM" "$ports_file" 2>/dev/null || echo "$PORT_NUM" >> "$ports_file"

    # Apply to all running containers
    running=$(docker ps --filter "name=^devbox-" --format '{{.Names}}' | grep -v '^devbox-traefik$')
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
    if [ -n "$PROJECT_FILTER" ]; then
        name="devbox-${PROJECT_FILTER}"
        if docker ps --filter "name=^${name}$" --format '{{.ID}}' | grep -q .; then
            docker stop "$name" > /dev/null
            docker rm "$name" > /dev/null
            docker volume rm "devbox-${PROJECT_FILTER}-docker" > /dev/null
            rm -f "$TRAEFIK_CONFIG_DIR/${name}"*.yml 2>/dev/null
            echo "Zastaven: $name"
            stop_traefik_if_idle
            exit 0
        fi
        echo "Kontejner $name neběží." >&2
    fi
    # No argument or container not found → interactive selection
    selected=$(pick_container "Zastavit kontejner: " "with_all") || exit 1
    if [ "$selected" = "* Zastavit všechny" ]; then
        docker ps --filter "name=^devbox-" --format '{{.Names}}' | grep -v '^devbox-traefik$' | while IFS= read -r c; do
            proj="${c#devbox-}"
            docker stop "$c" > /dev/null
            docker rm "$c" > /dev/null
            docker volume rm "devbox-${proj}-docker" > /dev/null
            rm -f "$TRAEFIK_CONFIG_DIR/${c}"*.yml 2>/dev/null
            echo "Zastaven: $c"
        done
        stop_traefik_if_idle
    else
        proj="${selected#devbox-}"
        docker stop "$selected" > /dev/null
        docker rm "$selected" > /dev/null
        docker volume rm "devbox-${proj}-docker" > /dev/null
        rm -f "$TRAEFIK_CONFIG_DIR/${selected}"*.yml 2>/dev/null
        echo "Zastaven: $selected"
        stop_traefik_if_idle
    fi
    exit 0
fi

# --- devbox blocked -----------------------------------------------------------

if [ "$MODE" = "blocked" ]; then
    containers=$(docker ps --filter "name=^devbox-" --format '{{.Names}}' | grep -v '^devbox-traefik$')
    if [ -z "$containers" ]; then
        echo "Žádné běžící devbox kontejnery."
        exit 0
    fi

    # Collect blocked IPs from all containers
    blocked=""
    while IFS= read -r container; do
        result=$(docker exec -u root "$container" bash -c \
            'dmesg 2>/dev/null | grep "DEVBOX_BLOCKED" | grep -oP "DST=\K[0-9.]+" | sort -u' || true)
        [ -n "$result" ] && blocked=$(printf '%s\n%s' "$blocked" "$result")
    done <<< "$containers"
    blocked=$(echo "$blocked" | grep -v '^$' | sort -u)

    if [ -z "$blocked" ]; then
        echo "Žádná blokovaná spojení."
        exit 0
    fi

    # Pick first container for reverse DNS lookups
    first_container=$(echo "$containers" | head -1)

    # Reverse-resolve IPs and build menu
    declare -a ips=()
    declare -a labels=()
    while IFS= read -r ip; do
        [ -z "$ip" ] && continue
        ips+=("$ip")
        hostname=$(docker exec "$first_container" bash -c "host $ip 2>/dev/null | grep -oP 'pointer \K.*' | sed 's/\.$//' || true")
        if [ -n "$hostname" ]; then
            labels+=("$ip ($hostname)")
        else
            labels+=("$ip")
        fi
    done <<< "$blocked"

    echo "Blokovaná spojení:"
    echo ""
    for i in "${!labels[@]}"; do
        echo "  $((i + 1))) ${labels[$i]}"
    done
    echo "  a) Povolit všechny"
    echo "  q) Zrušit"
    echo ""
    printf "Vyber (číslo/a/q): "
    read -r choice

    if [ "$choice" = "q" ]; then
        exit 0
    elif [ "$choice" = "a" ]; then
        selected_ips=("${ips[@]}")
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#ips[@]}" ]; then
        selected_ips=("${ips[$((choice - 1))]}")
    else
        echo "Neplatná volba." >&2
        exit 1
    fi

    for ip in "${selected_ips[@]}"; do
        hostname=$(docker exec "$first_container" bash -c "host $ip 2>/dev/null | grep -oP 'pointer \K.*' | sed 's/\.$//' || true")
        if [ -n "$hostname" ]; then
            "$0" allow "$hostname"
        else
            echo "Nelze přeložit IP $ip na doménu, přidávám přímo do ipset..."
            while IFS= read -r c; do
                docker exec -u root "$c" bash -c "ipset add allowed-domains '$ip' 2>/dev/null || true"
            done <<< "$containers"
        fi
    done
    exit 0
fi

# --- devbox allow <domain> ----------------------------------------------------

if [ "$MODE" = "allow" ]; then
    if [ -z "${DOMAIN:-}" ]; then
        # No domain specified → delegate to blocked for interactive selection
        exec "$0" blocked
    fi

    # Write domain to shared host file
    CONF="$HOME/.devbox/allowed-domains.conf"
    mkdir -p "$HOME/.devbox"
    touch "$CONF"

    if grep -qxF "$DOMAIN" "$CONF" 2>/dev/null; then
        echo "Již povoleno: $DOMAIN"
    else
        echo "$DOMAIN" >> "$CONF"
        echo "Povoleno: $DOMAIN"
    fi

    # Reload dnsmasq in all running containers
    containers=$(docker ps --filter "name=^devbox-" --format '{{.Names}}' | grep -v '^devbox-traefik$')
    if [ -n "$containers" ]; then
        while IFS= read -r container; do
            docker exec -u root "$container" bash -c "
                # Regenerate runtime config from shared file
                > /etc/dnsmasq.d/devbox-runtime.conf
                while IFS= read -r line; do
                    line=\$(echo \"\$line\" | sed 's/#.*//' | xargs)
                    [ -n \"\$line\" ] && echo \"ipset=/\${line}/allowed-domains\" >> /etc/dnsmasq.d/devbox-runtime.conf
                done < /etc/devbox-shared/allowed-domains.conf
                # Restart dnsmasq
                pkill dnsmasq || true
                dnsmasq --conf-dir=/etc/dnsmasq.d --keep-in-foreground &
                sleep 0.5
                nslookup '$DOMAIN' 127.0.0.1 > /dev/null 2>&1 || true
            " && echo "  Reloaded: $container" || echo "  Failed: $container" >&2
        done <<< "$containers"
    fi
    exit 0
fi

# --- Auto mode: create or attach ---------------------------------------------

if [ -d "${1:-.}" ]; then
    # Argument is a directory (or none → CWD) → create/attach mode
    PROJECT_PATH="$(realpath "${1:-.}")"
    PROJECT_NAME="$(basename "$PROJECT_PATH")"
    CONTAINER_NAME="devbox-$(sanitize "$PROJECT_NAME")"

    if docker ps --filter "name=^${CONTAINER_NAME}$" --format '{{.ID}}' | grep -q .; then
        attach_to_container "$CONTAINER_NAME"
        # exec → script ends here
    fi

    # Container not running → create new one (detached) below
else
    # Argument is not a directory → attach by name
    CONTAINER_NAME="devbox-${1}"
    if docker ps --filter "name=^${CONTAINER_NAME}$" --format '{{.ID}}' | grep -q .; then
        attach_to_container "$CONTAINER_NAME"
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

# Ensure agent has keys loaded
if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
    if ! ssh-add -l &>/dev/null; then
        echo "SSH agent has no keys, adding default keys..."
        ssh-add
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
    # Shared volumes
    -v devbox-claude-config:/home/node/.claude
    -v devbox-nvim-data:/home/node/.local/share/nvim
    -v devbox-cursor-server:/home/node/.cursor-server
    -e CLAUDE_CONFIG_DIR=/home/node/.claude
    # Git config from host (system-level so Cursor/VS Code can write to ~/.gitconfig)
    -v "$HOME/.gitconfig:/etc/gitconfig:ro"
    # SSH config only (no private keys)
    -v "$HOME/.ssh/config:/home/node/.ssh/config:ro"
    -v "$HOME/.ssh/known_hosts:/home/node/.ssh/known_hosts:ro"
)

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

# Shared firewall allowlist (host → all containers, read-only)
DEVBOX_CONFIG_DIR="$HOME/.devbox"
mkdir -p "$DEVBOX_CONFIG_DIR"
touch "$DEVBOX_CONFIG_DIR/allowed-domains.conf"
DOCKER_ARGS+=(-v "$DEVBOX_CONFIG_DIR/allowed-domains.conf:/etc/devbox-shared/allowed-domains.conf:ro")

# Mount workspace
DOCKER_ARGS+=(-v "$PROJECT_PATH:/workspace")

# --- Start detached container ------------------------------------------------

# Print warnings just before starting container (so they're visible)
if [ -n "$SSH_WARNING" ]; then
    echo "$SSH_WARNING"
fi

echo "Mounting project: $PROJECT_PATH -> /workspace ($CONTAINER_NAME)"
echo "Starting devbox..."

# Start container in background
docker run -d --name "$CONTAINER_NAME" "${DOCKER_ARGS[@]}" "$IMAGE" tail -f /dev/null

# Apply default port routes
apply_port_routes "$CONTAINER_NAME"

# Show URL info
ports_file="$HOME/.devbox/default-ports.conf"
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
docker exec -u root "$CONTAINER_NAME" bash -c \
    '/usr/local/bin/init-firewall.sh'
docker exec "$CONTAINER_NAME" bash -c \
    '/usr/local/bin/start-rootless-docker.sh && /usr/local/bin/setup-chezmoi.sh && /usr/local/bin/setup-claude.sh'

# Attach first interactive session
exec docker exec -it -w /workspace "$CONTAINER_NAME" zsh
