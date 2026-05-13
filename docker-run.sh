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
  devbox ports [--all] [--external]
                                   List active port routes (default: running
                                   containers, only listening ports)
  devbox connect                   Pick source, target devboxes, and services
  devbox connect <target> <port>   Forward one TCP port to another devbox
                                   (use 10.0.2.2:<local-port> from inner Docker)
  devbox connections               List cross-devbox TCP forwards
  devbox build [flags]             Build/rebuild the devbox image
  devbox update                    Update devbox (pull repo + rebuild image)
  devbox migrate                   Migrate data to new layout (interactive; auto-run by 'devbox update')
  devbox migrate-naming            Rename legacy non-LDH containers/volumes (auto-run by 'devbox update')
  devbox dns-install [--local|--external]
                                   Configure host resolver for *.test (per-OS)
  devbox dns-status                Show DNS mode + resolver state + verification
  devbox dns-uninstall             Remove host resolver config + dns.conf
  devbox uninstall [--purge-ca]    Remove everything (containers, volumes, image).
                                   --purge-ca also strips the mkcert root CA
                                   from system trust stores (UAC on WSL2).
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
  devbox port 3000                 Route 3000.<project>.test (and external fallback URL)
  devbox connect                   Interactive cross-devbox service picker
  devbox connect api 5432          Forward current devbox -> devbox-api:5432
  devbox connect db 5432 15432     Use an explicit local forward port
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
CONNECT_CONFIG_DIR="$HOME/.config/devbox/connect"
DNS_CONFIG_DIR="$HOME/.config/devbox/dns"

# Container names that belong to shared devbox infrastructure, not to any
# user project. Enumeration / cleanup sites filter these out via
# `filter_user_containers` so per-project loops never accidentally stop or
# tear down the shared proxy / resolver.
#
# Naming convention: shared infra uses an UNDERSCORE separator
# (`devbox_traefik`, `devbox_dns`) — `devbox::sanitize` converts `_` to
# `-`, so no user project token can ever produce these names, making the
# project / infra namespaces provably disjoint (see ADR 0007).
#
# Legacy dash-separator names (`devbox-traefik`, `devbox-dns`) are listed
# here only for the migration window — `scripts/migrate-shared-infra-naming.sh`
# (auto-triggered by `devbox update`) stops and removes them so the next
# bootstrap recreates them under the new names. Once a user has run
# `devbox update`, the legacy entries are dead code, kept defensively so
# enumeration during the transition window cannot misclassify a legacy
# infra container as a user project.
DEVBOX_SHARED_CONTAINER_NAMES=(
    devbox_traefik
    devbox_dns
    devbox-traefik
    devbox-dns
)

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

# HTTPS state + cert lifecycle modules. Sourced unconditionally — every entry
# point that touches cert files gates on `devbox::https_active`, which is
# false until the user opts in via dns-install --enable-https (Phase 6). See
# lib/https.sh, lib/mkcert.sh, lib/cert.sh and docs/adr/0008.
# shellcheck source=lib/https.sh
source "$DEVBOX_DIR/lib/https.sh"
# shellcheck source=lib/mkcert.sh
source "$DEVBOX_DIR/lib/mkcert.sh"
# shellcheck source=lib/cert.sh
source "$DEVBOX_DIR/lib/cert.sh"

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

# Filter a stream of `docker ps` output (one container per line, optional
# tab-separated extra fields) down to user-owned devbox containers. Drops
# DEVBOX_SHARED_CONTAINER_NAMES entries. awk-based so empty result still
# exits 0 (unlike `grep -v` which needs trailing `|| true`).
filter_user_containers() {
    awk -F '\t' -v shared="${DEVBOX_SHARED_CONTAINER_NAMES[*]}" '
        BEGIN {
            n = split(shared, arr, " ")
            for (i = 1; i <= n; i++) excl[arr[i]] = 1
        }
        !($1 in excl)
    '
}

# Probe TCP listeners that would clash with our `-p 127.0.0.1:<port>:<port>`
# publish for Traefik. The conflict set is narrow:
#   - 127.0.0.1:<port>           direct overlap with our IPv4 bind.
#   - 0.0.0.0:<port> / *:<port>  IPv4 wildcard, also serves 127.0.0.1.
#   - [::]:<port>                IPv6 wildcard; with IPV6_V6ONLY=0 it also
#                                claims the IPv4 wildcard. We can't see
#                                the V6ONLY flag from a probe, so we
#                                flag it conservatively — false-positive
#                                aborts beat docker's nameless bind error.
# Listeners on other addresses coexist with our bind and are ignored:
#   - 127.0.0.2:<port> (or any other 127.x alias)
#   - [::1]:<port>               pure IPv6 loopback, distinct address
#                                family from 127.0.0.1.
#   - any non-loopback interface address (192.168.x.x:<port>, etc.).
#
# When held, echoes a single descriptive line (`pid <N> (<comm>)`
# when ss/lsof can see the owner; a "needs root to inspect" hint
# otherwise) and returns 0. When free, prints nothing and returns 1.
# Mirrors the predicate shape of _dns::port_53_held_by_other in
# scripts/dns-install.sh.
#
# Usage: _devbox::port_held_by_other <port>
_devbox::port_held_by_other() {
    local port="$1"
    local listeners=""
    if command -v ss >/dev/null 2>&1; then
        # ss -p surfaces `users:(("name",pid=N,fd=M))` when this process
        # (or root) can read the owning task; column is empty otherwise.
        # awk's dynamic-regex form double-escapes backslashes: `\\.` in the
        # literal collapses to `\.` for the regex engine.
        listeners="$(ss -lntp 2>/dev/null \
            | awk -v port="$port" 'NR>1 && $4 ~ "(^127\\.0\\.0\\.1|^0\\.0\\.0\\.0|^\\*|^\\[::\\]):"port"$"')"
    elif command -v lsof >/dev/null 2>&1; then
        # lsof NAME column always has the form `<addr>:<port> (LISTEN)`;
        # match the conflict-set addresses explicitly so a service bound
        # to e.g. 192.168.x.x:<port> or [::1]:<port> doesn't block startup.
        # This matters most on macOS, where ss is absent and lsof is the path.
        listeners="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null \
            | awk -v port="$port" 'NR>1 && $0 ~ " (127\\.0\\.0\\.1|0\\.0\\.0\\.0|\\*|\\[::\\]):"port" \\(LISTEN\\)$"')"
    else
        # No probe tool available — we cannot prove a conflict, so let
        # docker run surface the bind error in its own words.
        return 1
    fi
    [ -n "$listeners" ] || return 1

    local desc=""
    if command -v ss >/dev/null 2>&1; then
        desc="$(printf '%s\n' "$listeners" \
            | grep -oE 'users:\(\("[^"]+",pid=[0-9]+' \
            | sed -E 's/users:\(\("([^"]+)",pid=([0-9]+)/pid \2 (\1)/' \
            | head -1)"
    else
        desc="$(printf '%s\n' "$listeners" | awk 'NR==1 {printf "pid %s (%s)", $2, $1}')"
    fi
    [ -z "$desc" ] && desc="(listener present; rerun with sudo to see PID)"
    printf '%s\n' "$desc"
    return 0
}

# Tell whether the existing devbox_traefik container was started in HTTPS
# mode. We look for the websecure entrypoint flag in `docker inspect` because
# the container's `docker run` args are the single source of truth: bind
# mounts and port publishes are fixed at create time, so the flag's presence
# in `.Config.Cmd` cleanly distinguishes a HTTP-only container from an
# HTTPS-capable one regardless of run/exited state.
# Returns 0 (HTTPS) when the flag is set, 1 (HTTP-only or no container).
_devbox::traefik_has_https() {
    docker inspect devbox_traefik 2>/dev/null \
        | grep -q -- '--entrypoints.websecure.address=:443'
}

# Effective URL scheme to advertise to the user — `https` only when both the
# persisted `https_active` opt-in is on AND the running devbox_traefik was
# actually started with the `websecure` entrypoint. Combining both checks
# closes the degraded-HTTPS hole: bootstrap_traefik can downgrade to HTTP-only
# when 127.0.0.1:443 is held at startup, and apply_port_routes then writes
# `web` routers via the same _devbox::traefik_has_https gate — so displayed
# URLs must follow the running mode, not the persisted wish, or every printed
# `https://` URL would 404. Returns the bare scheme (no `://`) so URL shape
# stays explicit at the call site.
devbox::url_scheme() {
    if devbox::https_active && _devbox::traefik_has_https; then
        printf '%s' 'https'
    else
        printf '%s' 'http'
    fi
}

bootstrap_traefik() {
    docker network inspect devproxy >/dev/null 2>&1 || docker network create devproxy

    mkdir -p "$TRAEFIK_CONFIG_DIR"
    seed_allowed_domains
    seed_default_ports

    # Reconcile a degraded HTTPS start. When `https_active` is on but the
    # existing devbox_traefik was created HTTP-only (a previous run hit a
    # transient 127.0.0.1:443 squatter and downgraded), recreate it as soon
    # as port 443 is free again — otherwise the WARN's promise that "freeing
    # 443 and re-running enables HTTPS" would silently fail forever, because
    # neither the restart-if-exited branch nor the run-if-missing branch
    # below ever touches a present container. We only flip the HTTP → HTTPS
    # direction; HTTPS → HTTP belongs to Phase 6's active migration once the
    # user explicitly opts out via dns-install --disable-https.
    if docker ps -a --filter "name=^devbox_traefik$" --format '{{.ID}}' | grep -q .; then
        if devbox::https_active \
            && ! _devbox::traefik_has_https \
            && ! _devbox::port_held_by_other 443 >/dev/null; then
            echo "Recreating Traefik to enable HTTPS (127.0.0.1:443 is now free)..."
            docker stop devbox_traefik >/dev/null 2>&1 || true
            docker rm devbox_traefik >/dev/null
        fi
    fi

    # If traefik exists but is exited, restart it. The container's docker run
    # args are baked in at create time, so a flip in `https_active` since the
    # previous start is not picked up here — that path is owned by Phase 6's
    # active migration (stop + remove + start). The reconcile block above
    # already handles the one Phase-4 case where the persistent intent is
    # HTTPS but the running container is HTTP-only.
    if docker ps -a --filter "name=^devbox_traefik$" --filter "status=exited" --format '{{.ID}}' | grep -q .; then
        echo "Restarting Traefik proxy..."
        docker start devbox_traefik
        return
    fi

    if ! docker ps --format '{{.Names}}' | grep -qx devbox_traefik; then
        # Pre-flight: docker run -p 127.0.0.1:80:80 would fail with
        # "bind: address already in use" but never names the offender.
        # Probe first so we can fail loud with PID + comm — the user can
        # stop the process or remap its port in a single step.
        local owner
        if owner="$(_devbox::port_held_by_other 80)"; then
            echo -e "\033[1;31m==> Cannot start Traefik: 127.0.0.1:80 is occupied by ${owner}\033[0m" >&2
            echo "    Stop that process (or remap its port) and re-run." >&2
            exit 1
        fi

        # Resolve the effective HTTPS mode for this `docker run`. We branch
        # off `devbox::https_active` (the persisted opt-in) but downgrade to
        # off when 127.0.0.1:443 is already taken: serving HTTP-only is
        # strictly better than aborting the whole devbox start. The persisted
        # https.conf is left alone — a transient port-443 squatter must not
        # silently flip the user's preference.
        local https_mode="off"
        if devbox::https_active; then
            local owner443
            if owner443="$(_devbox::port_held_by_other 443)"; then
                echo -e "\033[1;33mWARN: HTTPS disabled for this Traefik start — 127.0.0.1:443 is occupied by ${owner443}.\033[0m" >&2
                echo "      Free port 443 and re-run to enable HTTPS; HTTP-only routing continues meanwhile." >&2
            else
                https_mode="on"
            fi
        fi

        echo "Starting Traefik proxy..."

        # Build the publish, mount, and Traefik flag sets as arrays so the
        # HTTPS branch is a single additive block instead of duplicated
        # docker-run invocations.
        local -a publish_args=(
            -p 127.0.0.1:80:80
        )
        local -a mount_args=(
            -v /var/run/docker.sock:/var/run/docker.sock:ro
            -v "$TRAEFIK_CONFIG_DIR:/etc/traefik/dynamic:ro"
        )
        local -a traefik_args=(
            --providers.docker=true
            --providers.docker.exposedbydefault=false
            --providers.docker.network=devproxy
            --providers.file.directory=/etc/traefik/dynamic
            --providers.file.watch=true
            --entrypoints.web.address=:80
        )

        if [ "$https_mode" = "on" ]; then
            # Ensure the certs dir exists before docker bind-mounts it,
            # otherwise the daemon would create it as root-owned and
            # subsequent host-side cert writes by ensure_project_cert
            # (running as the user) would fail.
            mkdir -p "$DEVBOX_CERTS_DIR"
            publish_args+=(-p 127.0.0.1:443:443)
            mount_args+=(-v "$DEVBOX_CERTS_DIR:$DEVBOX_CERT_CONTAINER_PATH:ro")
            # Permanent 301 from web → websecure happens at the entrypoint
            # level, before any router rule evaluates, so every HTTP request
            # to any host gets redirected. The websecure entrypoint serves
            # the per-project leaf certs picked up via the file provider's
            # <project>-tls.yml fragments written by _cert::write_tls_yml.
            traefik_args+=(
                --entrypoints.websecure.address=:443
                --entrypoints.web.http.redirections.entrypoint.to=websecure
                --entrypoints.web.http.redirections.entrypoint.scheme=https
                --entrypoints.web.http.redirections.entrypoint.permanent=true
            )
        fi

        docker run -d --name devbox_traefik --restart unless-stopped \
            --network devproxy \
            "${publish_args[@]}" \
            "${mount_args[@]}" \
            traefik:v3 \
            "${traefik_args[@]}"
    fi
}

seed_allowed_domains() {
    allowlist::ensure_seeded "$ALLOWLIST_HOST_FILE" "$DEVBOX_DIR/config/default-allowlist.conf"
}

# Keep ~/.config/devbox/dns/devbox.conf bit-for-bit identical to the
# baked-in template at $DEVBOX_DIR/config/dns/devbox.conf. Two scenarios
# are handled here, both transparent to the user:
#
#   1. Missing file        → seed from template (first run).
#   2. Template drifted    → in-place rewrite + restart devbox_dns if it
#                            is running, so dnsmasq picks up the new
#                            config. SIGHUP is NOT enough — dnsmasq's
#                            documented SIGHUP semantics explicitly skip
#                            re-reading the config file.
#
# The rewrite path uses `cat > "$runtime"` (not `rm + cp`) so the file's
# inode stays the same. Docker Desktop snapshots bind-mounted files
# under /run/desktop/mnt/host/...; an unlink-then-create cycle invalidates
# the snapshot, and the next `docker restart devbox_dns` then fails with
# "mount src ... no such file or directory" — observed during the
# listen-address fix rollout.
#
# Custom user edits to the runtime file are NOT preserved: this is
# internal devbox plumbing and the template owns the canonical config.
# Per-host dnsmasq tweaks should patch config/dns/devbox.conf in the
# repo (which then ships through this mechanism to every install).
ensure_dns_runtime_config() {
    local template="$DEVBOX_DIR/config/dns/devbox.conf"
    local runtime="$DNS_CONFIG_DIR/devbox.conf"
    mkdir -p "$DNS_CONFIG_DIR"

    if [ ! -f "$runtime" ]; then
        cat "$template" > "$runtime"
        return 0
    fi

    if cmp -s "$template" "$runtime"; then
        return 0
    fi

    echo "Refreshing devbox_dns config from updated template..."
    cat "$template" > "$runtime"
    if docker ps --format '{{.Names}}' | grep -qx devbox_dns; then
        docker restart devbox_dns >/dev/null
    fi
}

# Restore ~/.config/devbox/dns.conf when the meta config has gone missing
# but a previous local-mode install left state behind. devbox_dns is only
# ever created by bootstrap_dns in local mode (external mode skips the
# container entirely), so its presence — running or stopped — is a safe
# tell that the user was on local mode before the file vanished.
#
# Does NOT auto-invoke `devbox dns-install`: that path writes host
# resolver files and prompts for sudo / UAC, neither of which belongs
# mid-`devbox <project>` invocation. Active reinstall on missing meta
# config is reserved for `devbox update` in Phase 5 of ADR 0007.
ensure_dns_meta_config() {
    local conf="$HOME/.config/devbox/dns.conf"
    [ -f "$conf" ] && return 0
    docker ps -a --filter "name=^devbox_dns$" --format '{{.ID}}' | grep -q . || return 0

    mkdir -p "$(dirname "$conf")"
    cat > "$conf" <<EOF
# Restored after dns.conf went missing — devbox inferred local mode from
# the existing devbox_dns container. Re-run 'devbox dns-install' if you
# need host resolver setup or want a different mode.
preferred=local
active_domain=$DEVBOX_LOCAL_TLD
external_provider=sslip.io
EOF
    devbox::reset_dns_cache
    echo "Restored ~/.config/devbox/dns.conf (inferred local mode from devbox_dns container)."
}

# Start the devbox_dns dnsmasq container in local mode (active_domain=test).
# Skipped in external mode — sslip.io needs no host-side resolver. Mirrors
# bootstrap_traefik: lazy network create, restart-if-exited, run-if-missing.
#
# Runs dnsmasq as root inside the container so it can bind the privileged
# port 53; the host-side port mapping stays loopback-only per ADR 0007.
#
# Image guard: the resolver reuses the devbox image (dnsmasq is already
# baked in per ADR 0001). On a clean checkout without `devbox build`, the
# image is absent; we degrade with a visible WARNING rather than letting
# `docker run` implicit-pull an unrelated `vlcak/devbox:latest` from a
# registry. The user's own container creation later in this script still
# fails-loud at its own image-inspect guard.
bootstrap_dns() {
    # Phase 4 self-heal: ensure_dns_meta_config runs first because it can
    # flip the active mode (when dns.conf was missing and we infer local
    # from container presence), which then affects the route_domain guard.
    ensure_dns_meta_config

    [ "$(devbox::route_domain)" = "$DEVBOX_LOCAL_TLD" ] || return 0

    if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
        echo "WARNING: devbox_dns not started — image $IMAGE not built locally." >&2
        echo "         .test URLs will not resolve from the host until you run: devbox build" >&2
        return 0
    fi

    docker network inspect devproxy >/dev/null 2>&1 || docker network create devproxy
    ensure_dns_runtime_config

    if docker ps -a --filter "name=^devbox_dns$" --filter "status=exited" --format '{{.ID}}' | grep -q .; then
        echo "Restarting DNS resolver..."
        docker start devbox_dns
        return
    fi

    if ! docker ps --format '{{.Names}}' | grep -qx devbox_dns; then
        echo "Starting DNS resolver..."
        docker run -d --name devbox_dns --pull=never --restart unless-stopped \
            --network devproxy \
            -u root \
            -p 127.0.0.1:53:53/udp \
            -p 127.0.0.1:53:53/tcp \
            -v "$DNS_CONFIG_DIR/devbox.conf:/etc/devbox-dns.conf:ro" \
            --entrypoint dnsmasq \
            "$IMAGE" \
            --keep-in-foreground --conf-file=/etc/devbox-dns.conf
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

# Phase 3 hook: when HTTPS is active, refresh the per-project leaf cert and
# Traefik TLS file-provider config before route files are written. Until
# Phase 4 flips https_active on, this is a noop. Failures inside the cert
# pipeline are non-fatal — devbox keeps serving HTTP-only routes — and the
# cert lib emits its own colored WARN lines so no failure goes silent.
ensure_https_for_container() {
    local container="$1"
    devbox::https_active || return 0
    local project="${container#devbox-}"
    ensure_project_cert "$project" || true
}

apply_port_routes() {
    local container="$1"
    local project="${container#devbox-}"
    ensure_https_for_container "$container"
    local ports_file="$HOME/.config/devbox/default-ports.conf"
    [ -f "$ports_file" ] || return 0

    # Decide the entrypoint flavor once per call based on the *running*
    # Traefik, not the persisted opt-in. When `https_active=true` but
    # 127.0.0.1:443 was held at bootstrap, bootstrap_traefik silently
    # downgrades the container to HTTP-only — pointing routers at a
    # non-existent `websecure` entrypoint would then 404 every port.
    # Every apply_port_routes call site (main flow, restart_exited_container,
    # `devbox port`) runs after bootstrap_traefik has materialised the
    # Traefik container in its effective mode, so the inspect result is
    # authoritative. The persisted flag still drives ensure_https_for_container
    # above so per-project certs keep getting refreshed in the background:
    # the moment port 443 frees and bootstrap_traefik recreates Traefik
    # with `websecure`, the next apply_port_routes pass flips the YAML.
    local websecure_mode="false"
    if _devbox::traefik_has_https; then
        websecure_mode="true"
    fi

    while read -r port _rest; do
        port="${port%%#*}"
        [ -z "$port" ] && continue

        local host_rule="" sep="" host
        while IFS= read -r host; do
            host_rule+="${sep}Host(\`${host}\`)"
            sep=" || "
        done < <(devbox::route_hosts "$project" "$port")
        local config_file="${TRAEFIK_CONFIG_DIR}/${container}-${port}.yml"
        local router_name="${container}-${port}"

        # `tls: {}` makes Traefik pick the matching cert out of the
        # per-project <project>-tls.yml fragment written by
        # _cert::write_tls_yml (via ensure_https_for_container above). The
        # entrypoint-level web→websecure redirect set by bootstrap_traefik
        # means we don't list `web` here at all when HTTPS is on — every
        # HTTP hit is upgraded before any router rule runs.
        if [ "$websecure_mode" = "true" ]; then
            cat > "$config_file" <<YAML
http:
  routers:
    ${router_name}:
      rule: "${host_rule}"
      entryPoints:
        - websecure
      tls: {}
      service: ${router_name}
  services:
    ${router_name}:
      loadBalancer:
        servers:
          - url: "http://${container}:${port}"
YAML
        else
            cat > "$config_file" <<YAML
http:
  routers:
    ${router_name}:
      rule: "${host_rule}"
      entryPoints:
        - web
      service: ${router_name}
  services:
    ${router_name}:
      loadBalancer:
        servers:
          - url: "http://${container}:${port}"
YAML
        fi
    done < "$ports_file"
}

# Remove per-project HTTPS artifacts (leaf cert + key + meta + Traefik TLS
# fragment). Companion to the existing `rm -f $TRAEFIK_CONFIG_DIR/<container>*.yml`
# route-file cleanup in the stop path: that glob catches the per-port route
# files (matching the `<container>-<port>.yml` naming in apply_port_routes)
# but leaves the cert files under $DEVBOX_CERTS_DIR and the project-scoped
# `<project>-tls.yml` fragment behind because both lack the `devbox-` prefix
# the glob keys off. Without this helper, a `devbox stop` would orphan the
# TLS YAML — and on the next `devbox <project>` Traefik's file watcher
# would still load it, advertising a cert for a project that no longer has
# routes. Silent (2>/dev/null) so a freshly-stopped project that never had
# HTTPS active doesn't generate spurious WARNs.
#
# Usage: _devbox::remove_project_https_artifacts <project>
_devbox::remove_project_https_artifacts() {
    local project="$1"
    [ -n "$project" ] || return 0
    rm -f \
        "$DEVBOX_CERTS_DIR/${project}.pem" \
        "$DEVBOX_CERTS_DIR/${project}.key" \
        "$DEVBOX_CERTS_DIR/${project}.meta" \
        "$DEVBOX_CERT_TLS_DIR/${project}-tls.yml" \
        2>/dev/null || true
}

# --- HTTPS lifecycle orchestration (ADR 0008 Phase 6) ------------------------

# Helper used by both upgrade and downgrade paths: emit the unique list of
# per-project containers that currently have at least one `<container>-<port>.yml`
# under $TRAEFIK_CONFIG_DIR. Stdin is unused; output one container name per
# line. Empty when the dir is missing or contains no per-project files.
_devbox::list_routed_containers() {
    [ -d "$TRAEFIK_CONFIG_DIR" ] || return 0
    local f base suffix
    {
        for f in "$TRAEFIK_CONFIG_DIR"/devbox-*-*.yml; do
            [ -f "$f" ] || continue
            base="$(basename "$f" .yml)"
            # Only per-project route files have a numeric port as their
            # final dash-segment. <project>-tls.yml fragments emitted by
            # _cert::write_tls_yml (and any future non-route dynamic
            # config) end on a non-numeric suffix — stripping the last
            # dash group would otherwise yield a bogus container name for
            # any project whose own sanitized name starts with `devbox-`
            # (e.g. project `devbox-foo` has both `devbox-devbox-foo-3000.yml`
            # AND `devbox-foo-tls.yml` under this dir).
            suffix="${base##*-}"
            case "$suffix" in
                ''|*[!0-9]*) continue ;;
            esac
            printf '%s\n' "${base%-*}"
        done
    } | sort -u
}

# Restore every `<name>.yml` from its `<name>.yml.pre-https-backup` sibling
# under $TRAEFIK_CONFIG_DIR. Used by the HTTPS upgrade rollback path when
# the post-bootstrap verification detects that Traefik came up HTTP-only
# despite migration already having rewritten the YAMLs. Iterating every
# backup file is safe even if some are leftovers from an earlier successful
# upgrade: those routes' .yml is currently websecure, and restoring the
# backup brings it back to its original HTTP form — which matches the
# `active=false` state the caller is rolling back to.
#
# Prints the number of files restored. Returns 0; missing backups or copy
# failures are reported on stderr but never bubble up — the caller has
# already committed to a rollback and there is nothing useful to abort to.
_devbox::restore_https_route_backups() {
    [ -d "$TRAEFIK_CONFIG_DIR" ] || return 0
    local b target restored=0
    for b in "$TRAEFIK_CONFIG_DIR"/*.pre-https-backup; do
        [ -f "$b" ] || continue
        target="${b%.pre-https-backup}"
        if cp "$b" "$target" 2>/dev/null; then
            restored=$((restored + 1))
        else
            echo "WARN: could not restore $target from $b" >&2
        fi
    done
    [ "$restored" -gt 0 ] \
        && echo "    Restored $restored route file(s) to HTTP from .pre-https-backup."
    return 0
}

# Full HTTPS upgrade orchestration. The two entry points that call it
# (`devbox update`'s prompt and `devbox dns-install --enable-https`) must
# go through the same path, otherwise the standalone command would only
# flip `active=true` and leave the running Traefik + every existing route
# file pointing at the wrong entrypoint — the regression Codex flagged in
# Phase 6 review round 3.
#
# Returns 0 on full success. Returns 1 on any failure, with `active=false`
# rolled back so the system ends in a coherent HTTP-only state. https.conf
# is intentionally left untouched on a 443-busy pre-flight bail: that is a
# transient blocker, not a user decision, so the next `devbox update` still
# offers the prompt.
_devbox::run_https_upgrade() {
    local owner443="" skip_port_check=0
    # Idempotency carve-out: if our own HTTPS-mode devbox_traefik is
    # already running, it is the listener on 127.0.0.1:443 and probing
    # for an "other" owner would spuriously flag ourselves and block a
    # re-enable. The orchestration below tears down and recreates that
    # container anyway, so a real external squatter would still surface
    # via bootstrap_traefik's own pre-flight + the post-recreate HTTPS
    # verification, which together drive the rollback path.
    if docker ps --filter "name=^devbox_traefik$" --format '{{.ID}}' | grep -q . \
        && _devbox::traefik_has_https; then
        skip_port_check=1
    fi
    if [ "$skip_port_check" -eq 0 ] && owner443="$(_devbox::port_held_by_other 443)"; then
        echo -e "\033[1;33m==> Cannot enable HTTPS now: 127.0.0.1:443 is occupied by ${owner443}.\033[0m"
        echo "    Free port 443, then rerun 'devbox dns-install --enable-https' (or 'devbox update')."
        echo "    https.conf is left untouched."
        return 1
    fi
    # `_DEVBOX_HTTPS_FLIP_ONLY=1` tells dns-install.sh that the wrapper
    # is driving the full lifecycle: it should do the bare state flip
    # (CA install + https.conf active=true) and skip the re-exec into
    # this orchestration that direct script invocations get routed
    # through.
    if ! _DEVBOX_HTTPS_FLIP_ONLY=1 "$DEVBOX_DIR/scripts/dns-install.sh" --enable-https; then
        echo -e "\033[1;31m==> HTTPS enable failed. Devbox stays HTTP-only; rerun 'devbox dns-install --enable-https' to retry.\033[0m"
        return 1
    fi
    # Drop the in-process cache so the migrator and the Traefik recreate
    # below both see `active=true` from the freshly-written https.conf
    # instead of the stale `false` we loaded when this command started.
    devbox::reset_https_cache
    if "$DEVBOX_DIR/scripts/migrate-routes-to-https.sh" --auto; then
        # Static Traefik flags (entrypoints, redirect) are baked in at
        # `docker run` time, so a live restart would keep the old HTTP-only
        # command line. Tear down and re-bootstrap right here — leaving
        # the recreate to the next `devbox <project>` would blackhole every
        # already-running project until the user touches one of them again.
        local recreated_traefik=0
        if docker ps -a --filter "name=^devbox_traefik$" --format '{{.ID}}' | grep -q .; then
            echo "Recreating devbox_traefik with HTTPS entrypoints..."
            docker stop devbox_traefik >/dev/null 2>&1 || true
            docker rm devbox_traefik >/dev/null 2>&1 || true
            # Subshell-wrap so bootstrap_traefik's own `exit 1` (fires when
            # 127.0.0.1:80 is grabbed in the race window) cannot tear down
            # the whole devbox process before we get to roll the upgrade
            # back. A docker-run failure in the function's final docker
            # invocation propagates the same way: the subshell exits with
            # the failing rc and `! ( ... )` catches it.
            if ! ( bootstrap_traefik ); then
                echo -e "\033[1;31m==> bootstrap_traefik failed during HTTPS recreate (likely a port :80/:443 race or docker run error).\033[0m" >&2
                echo "    Rolling back to HTTP — route files restored from backup, https.conf active=false." >&2
                _devbox::restore_https_route_backups
                devbox::write_https_field active false || true
                devbox::reset_https_cache
                return 1
            fi
            recreated_traefik=1
        fi
        # TOCTOU defence: a process could have grabbed 127.0.0.1:443 between
        # the pre-flight probe at the top of this function and the
        # bootstrap_traefik call above. bootstrap_traefik handles that by
        # downgrading the recreated container to HTTP-only and warning, but
        # it returns success — so without this check we would print
        # "HTTPS enabled" while every websecure route file points at an
        # entrypoint the container does not have. Verify the running
        # container really is HTTPS-capable; if not, roll the whole upgrade
        # back to a coherent HTTP-only state.
        #
        # Only meaningful when we actually recreated Traefik. On a clean
        # install where no devbox_traefik has ever existed,
        # `_devbox::traefik_has_https` necessarily returns false even
        # though https.conf is correct — the next `devbox <project>` will
        # be the one that bootstraps Traefik with HTTPS from that state.
        # Rolling back in that case would block the entire opt-in flow
        # before any project ever starts.
        if [ "$recreated_traefik" -eq 1 ] && ! _devbox::traefik_has_https; then
            echo -e "\033[1;31m==> Traefik came up HTTP-only despite the upgrade (port 443 was lost between pre-flight and recreate).\033[0m" >&2
            echo "    Rolling back to HTTP — route files restored from backup, https.conf active=false." >&2
            _devbox::restore_https_route_backups
            devbox::write_https_field active false || true
            devbox::reset_https_cache
            return 1
        fi
        echo ""
        echo -e "\033[1;32mHTTPS enabled. New URL format:\033[0m"
        echo "    https://<port>.<project>.${DEVBOX_LOCAL_TLD}"
        echo "    https://<port>.<project>.127.0.0.1.$(devbox::external_provider)"
        echo "    HTTP requests on :80 are 301-redirected to HTTPS."
        return 0
    fi
    # Partial migration. The migrator has already restored every file it
    # successfully rewrote from .pre-https-backup, so on-disk route YAMLs
    # are coherent HTTP again. All we need to do here is roll `active`
    # back: apply_port_routes will then stop emitting the websecure
    # template on future invocations, and the existing HTTP-only Traefik
    # keeps serving the (now HTTP-only) routes without a restart. The
    # user fixes the underlying issue (typically cert generation),
    # optionally inspects *.pre-https-backup for the would-be HTTPS body,
    # and reruns 'devbox dns-install --enable-https'.
    echo -e "\033[1;31m==> Route migration failed — aborting HTTPS upgrade.\033[0m"
    echo "    Route files have been restored to HTTP; *.pre-https-backup files in"
    echo "    $TRAEFIK_CONFIG_DIR are kept for inspection."
    echo "    Fix the cert / permission issue, then rerun 'devbox dns-install --enable-https'."
    echo "    https.conf rolled back to active=false."
    devbox::write_https_field active false || true
    devbox::reset_https_cache
    return 1
}

# Full HTTPS downgrade orchestration: rewrite every per-project route YAML
# back to the HTTP `web` template, tear down the HTTPS-mode Traefik, and
# recreate it HTTP-only. Used by `devbox dns-install --disable-https`.
#
# Order matters: a naive "stop HTTPS Traefik, rewrite YAMLs, bootstrap HTTP"
# sequence creates a brief window where the HTTPS Traefik is gone but new
# YAMLs are not yet written, so requests get connection-refused. That's
# unavoidable because the static Traefik command line is fixed at create
# time; the alternative is bounded to that ~1s gap. We pick:
#
#   1. dns-install --disable-https              (flip active=false)
#   2. docker stop+rm devbox_traefik (if HTTPS) (so apply_port_routes branches HTTP)
#   3. apply_port_routes for every routed container (rewrite YAMLs)
#   4. bootstrap_traefik                        (recreate HTTP-only)
#
# Step 2 must come before step 3 because `_devbox::traefik_has_https` keys
# off `docker inspect`, not on `active` in https.conf — leaving the HTTPS
# container in place would have apply_port_routes keep emitting websecure.
_devbox::run_https_downgrade() {
    # Sentinel: see _devbox::run_https_upgrade for the rationale. Tells
    # dns-install.sh to do the bare https.conf flip instead of recursing
    # back through this orchestration via 'devbox dns-install ...'.
    if ! _DEVBOX_HTTPS_FLIP_ONLY=1 "$DEVBOX_DIR/scripts/dns-install.sh" --disable-https; then
        echo -e "\033[1;31m==> HTTPS disable failed (https.conf write error). Aborting.\033[0m" >&2
        return 1
    fi
    devbox::reset_https_cache

    local had_https_traefik=0
    if docker inspect devbox_traefik 2>/dev/null \
        | grep -q -- '--entrypoints.websecure.address=:443'; then
        had_https_traefik=1
        echo "Removing HTTPS-mode devbox_traefik..."
        docker stop devbox_traefik >/dev/null 2>&1 || true
        docker rm devbox_traefik >/dev/null 2>&1 || true
    fi

    # Rewrite every per-project route YAML via the live apply_port_routes
    # template. Now that the HTTPS Traefik is gone, `_devbox::traefik_has_https`
    # returns false, so apply_port_routes emits the `web` branch for every
    # container. Files for ports that are no longer listed in
    # default-ports.conf are not touched here — same behavior as
    # `devbox port`'s reroute pass.
    local rewritten=0 container
    while IFS= read -r container; do
        [ -z "$container" ] && continue
        apply_port_routes "$container"
        rewritten=$((rewritten + 1))
    done < <(_devbox::list_routed_containers)

    # Recreate Traefik HTTP-only. bootstrap_traefik handles the "no
    # container exists" branch by running a fresh `docker run` with the
    # HTTP-only command line (because active=false now). When no Traefik
    # was running before (had_https_traefik=0), the recreate is still
    # cheap and converges the system to the expected state.
    #
    # Subshell-wrap so a port-:80 grab in the race window (which makes
    # bootstrap_traefik `exit 1`) does not abort the whole script after
    # we have already removed the old HTTPS Traefik. We cannot un-remove
    # what we already tore down, but degrading to a clean "config and
    # routes are HTTP-only, Traefik down" state with a loud message
    # leaves the user one `devbox <project>` away from recovery instead
    # of a script that died mid-orchestration.
    if [ "$had_https_traefik" -eq 1 ]; then
        if ! ( bootstrap_traefik ); then
            echo -e "\033[1;31m==> bootstrap_traefik failed during HTTP-only recreate (likely a port :80 race or docker run error).\033[0m" >&2
            echo "    https.conf and route files are coherent HTTP-only, but devbox_traefik is down." >&2
            echo "    Free port 80 and run 'devbox <project>' to bring Traefik back up." >&2
            return 1
        fi
    fi

    echo ""
    echo -e "\033[1;32mHTTPS disabled. URLs reverted to http://. Rewrote routes for ${rewritten} container(s).\033[0m"
    return 0
}

connection_config_file() {
    local source_project="$1"
    printf '%s/%s.tsv' "$CONNECT_CONFIG_DIR" "$source_project"
}

allocate_connection_port() {
    local source="$1" target="$2" target_port="$3" used_file="$4"
    local checksum candidate i
    checksum=$(printf '%s' "${source}:${target}:${target_port}" | cksum | awk '{print $1}')
    candidate=$((15000 + checksum % 1000))

    for i in $(seq 0 999); do
        local port=$((15000 + (candidate - 15000 + i) % 1000))
        if ! awk -F '\t' -v p="$port" '$4 == p { found=1 } END { exit found ? 0 : 1 }' "$used_file" 2>/dev/null; then
            printf '%s' "$port"
            return 0
        fi
    done

    echo "No free devbox connection port in 15000-15999." >&2
    return 1
}

start_container_connection() {
    local source_container="$1" target_container="$2" target_port="$3" local_port="$4" alias="$5"
    local log_file="/tmp/devbox-connect-${local_port}.log"
    local pid_file="/tmp/devbox-connect-${local_port}.pid"

    docker exec -u node \
        -e TARGET_CONTAINER="$target_container" \
        -e TARGET_PORT="$target_port" \
        -e LOCAL_PORT="$local_port" \
        -e CONNECT_ALIAS="$alias" \
        -e LOG_FILE="$log_file" \
        -e PID_FILE="$pid_file" \
        "$source_container" bash -lc '
            set -euo pipefail
            if ss -ltn "sport = :${LOCAL_PORT}" | grep -q ":${LOCAL_PORT}"; then
                exit 0
            fi
            if ! command -v socat >/dev/null 2>&1; then
                echo "socat is not installed in this devbox image." >&2
                exit 1
            fi
            rm -f "$PID_FILE"
            nohup socat TCP-LISTEN:"${LOCAL_PORT}",bind=127.0.0.1,reuseaddr,fork TCP:"${TARGET_CONTAINER}:${TARGET_PORT}" >"$LOG_FILE" 2>&1 &
            echo $! > "$PID_FILE"
        '
}

start_devbox_connections() {
    local container="$1"
    local source_project="${container#devbox-}"
    local config_file
    config_file="$(connection_config_file "$source_project")"
    [ -f "$config_file" ] || return 0

    while IFS=$'\t' read -r alias target_container target_port local_port; do
        [ -n "${alias:-}" ] || continue
        case "$alias" in \#*) continue ;; esac
        if start_container_connection "$container" "$target_container" "$target_port" "$local_port" "$alias"; then
            echo "Connection: ${alias} 10.0.2.2:${local_port} → ${target_container}:${target_port}"
        else
            echo "Failed to start connection ${alias} for ${container}." >&2
        fi
    done < "$config_file"
}

list_devbox_container_names() {
    docker ps --filter "name=^devbox-" --format '{{.Names}}' | filter_user_containers
}

# Probe LISTENING TCP ports inside a running container by reading
# /proc/net/tcp[6] directly — no binary inside the container is required.
# Prints ports newline-separated and sorted unique on stdout.
#
# Exit code is the signal to the caller:
#   0  probe succeeded (output may be empty = genuinely no listeners)
#   != probe failed   (docker exec hung/erroreded, container gone, no perms)
#
# Distinguishing the two matters so the `ports` command can hide routes only
# when the probe affirmatively found nothing, and fall back to "show all
# routes" if the probe itself was unreliable. Uses GNU `timeout` when
# available; macOS default install lacks it, so on those hosts the call
# runs unguarded — `docker exec` on a healthy container returns promptly,
# and a true hang there is a separate problem worth surfacing anyway.
list_listening_ports_in_container() {
    local container="$1" raw rc=0
    if command -v timeout >/dev/null 2>&1; then
        raw=$(timeout 3 docker exec "$container" sh -c 'cat /proc/net/tcp /proc/net/tcp6 2>/dev/null') || rc=$?
    else
        raw=$(docker exec "$container" sh -c 'cat /proc/net/tcp /proc/net/tcp6 2>/dev/null') || rc=$?
    fi
    [ "$rc" -ne 0 ] && return "$rc"
    printf '%s\n' "$raw" \
        | awk 'BEGIN { for (i = 0; i < 256; i++) hex[sprintf("%02X", i)] = i }
               $4 == "0A" {
                 n = split($2, parts, ":")
                 h = parts[n]
                 port = hex[substr(h, 1, 2)] * 256 + hex[substr(h, 3, 2)]
                 print port
               }' \
        | sort -un
}

discover_published_tcp_services() {
    local target_container="$1"
    local target_project="${target_container#devbox-}"
    local rows
    rows=$(docker exec -u node "$target_container" bash -lc \
        'docker ps --format "{{.Names}}\t{{.Ports}}"' 2>/dev/null || true)
    [ -n "$rows" ] || return 0

    while IFS=$'\t' read -r inner_name ports; do
        [ -n "${inner_name:-}" ] || continue
        [ -n "${ports:-}" ] || continue
        IFS=',' read -ra entries <<< "$ports"
        local entry
        for entry in "${entries[@]}"; do
            entry="${entry#"${entry%%[![:space:]]*}"}"
            entry="${entry%"${entry##*[![:space:]]}"}"
            [[ "$entry" == *"->"*"/tcp"* ]] || continue

            local left right host_port private_port
            left="${entry%%->*}"
            right="${entry#*->}"
            right="${right%%/*}"
            host_port="${left##*:}"
            private_port="$right"
            [[ "$host_port" =~ ^[0-9]+$ ]] || continue
            [[ "$private_port" =~ ^[0-9]+$ ]] || continue

            printf '%s\t%s\t%s\t%s\t%s\n' \
                "$target_project" "$target_container" "$inner_name" "$host_port" "$private_port"
        done
    done <<< "$rows"
}

upsert_connection_record() {
    local source_project="$1" alias="$2" target_container="$3" target_port="$4" local_port="$5"
    local config_file tmp
    config_file="$(connection_config_file "$source_project")"
    mkdir -p "$CONNECT_CONFIG_DIR"
    touch "$config_file"

    tmp="${config_file}.tmp"
    awk -F '\t' -v t="$target_container" -v p="$target_port" -v lp="$local_port" \
        'BEGIN { OFS = FS } !($2 == t && $3 == p) && !($4 == lp)' "$config_file" > "$tmp"
    printf '%s\t%s\t%s\t%s\n' "$alias" "$target_container" "$target_port" "$local_port" >> "$tmp"
    mv "$tmp" "$config_file"
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
    remaining=$(docker ps --filter "name=^devbox-" --format '{{.Names}}' | filter_user_containers)
    if [ -z "$remaining" ] && docker ps --format '{{.Names}}' | grep -qx devbox_traefik; then
        docker stop devbox_traefik > /dev/null
        docker rm devbox_traefik > /dev/null
        echo "Stopped: devbox_traefik (no remaining containers)"
    fi
}

stop_dns_if_idle() {
    local remaining
    remaining=$(docker ps --filter "name=^devbox-" --format '{{.Names}}' | filter_user_containers)
    if [ -z "$remaining" ] && docker ps --format '{{.Names}}' | grep -qx devbox_dns; then
        docker stop devbox_dns > /dev/null
        docker rm devbox_dns > /dev/null
        echo "Stopped: devbox_dns (no remaining containers)"
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
    start_devbox_connections "$name"
}

list_running_containers() {
    local containers
    containers=$(docker ps --filter "name=^devbox-" --format '{{.Names}}\t{{.Status}}\t{{.RunningFor}}' | filter_user_containers)
    if [ -z "$containers" ]; then
        echo "No running devbox containers."
    else
        printf '%-25s %-50s %s\n' "NAME" "URL" "STATUS"
        local scheme
        scheme="$(devbox::url_scheme)"
        while IFS=$'\t' read -r name status running; do
            local project url
            project="${name#devbox-}"
            url="${scheme}://$(devbox::route_host_display "$project" '<port>')"
            printf '%-25s %-50s %s\n' "$name" "$url" "$status"
        done <<< "$containers"
    fi

    local exited
    exited=$(docker ps -a --filter "name=^devbox-" --filter "status=exited" \
        --format '{{.Names}}\t{{.Status}}' | filter_user_containers)
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
    containers=$(docker ps --filter "name=^devbox-" --format '{{.Names}}' | filter_user_containers)
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
    running=$(docker ps -a --filter "name=^devbox-" --format '{{.Names}}' | filter_user_containers)

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
    connect) MODE="connect"; shift ;;
    connections) MODE="connections"; shift ;;
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
    dns-install)   MODE="dns-install";   shift ;;
    dns-status)    MODE="dns-status";    shift ;;
    dns-uninstall) MODE="dns-uninstall"; shift ;;
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
        # Auto-rename shared-infra containers from dash to underscore separator.
        # devbox-traefik → devbox_traefik, devbox-dns → devbox_dns. The new
        # separator can never be produced by `devbox::sanitize`, eliminating
        # the collision where a user project named `traefik` or `dns` would
        # land on the shared container name. See ADR 0007.
        if "$DEVBOX_DIR/scripts/migrate-shared-infra-naming.sh" --check; then
            echo ""
            echo -e "\033[1;36m==> Detected legacy shared-infra container names — migrating to underscore separator\033[0m"
            echo "    (Traefik / dnsmasq configs are bind-mounted; legacy containers removed, recreated on next devbox)"
            if ! "$DEVBOX_DIR/scripts/migrate-shared-infra-naming.sh" --auto; then
                echo -e "\033[1;31m==> Shared-infra naming migration FAILED. Aborting update.\033[0m"
                exit 1
            fi
        fi
        # Auto-rewrite Traefik dynamic configs that still reference the dead
        # traefik.me wildcard DNS into the new dual-`Host()` rule covering
        # both `.test` (local mode) and `.127.0.0.1.sslip.io` (external mode).
        # If dns.conf is missing the migration also runs `dns-install` so the
        # host resolver and the route configs end up consistent in one pass.
        # See ADR 0007 § "Migration from traefik.me".
        if "$DEVBOX_DIR/scripts/migrate-traefik-me-routes.sh" --check; then
            echo ""
            echo -e "\033[1;36m==> Detected Traefik routes referencing dead traefik.me — rewriting to dual-Host rule (.test || sslip.io)\033[0m"
            if ! "$DEVBOX_DIR/scripts/migrate-traefik-me-routes.sh" --auto; then
                echo -e "\033[1;31m==> traefik.me route migration FAILED. Aborting update.\033[0m"
                exit 1
            fi
        fi
        # HTTPS upgrade prompt (ADR 0008 Phase 6). Offered exactly once per
        # install: a user who declines flips `optout=true` in https.conf and
        # the prompt never fires again. A user who accepts ends up with
        # `active=true`, all running projects' routes rewritten to websecure,
        # and `devbox_traefik` recreated with the HTTPS entrypoints — every
        # state change is gated on a single UAC (Windows trust install).
        #
        # We only prompt on an interactive TTY: non-interactive `devbox update`
        # (e.g. from a CI cron) leaves https.conf untouched so a later
        # interactive update still gets the chance to ask.
        if ! devbox::https_active \
            && ! devbox::https_optout \
            && [ -t 0 ] && [ -t 1 ]; then
            echo ""
            echo -e "\033[1;36m==> Devbox can now serve every project over HTTPS with a locally-trusted cert.\033[0m"
            echo "    Enabling this:"
            echo "      - installs a mkcert-managed root CA into your host trust stores"
            echo "        (Linux/macOS native, plus Windows on WSL2 — fires UAC once)"
            echo "      - re-emits every existing route file with the websecure entrypoint"
            echo "      - recreates devbox_traefik with the HTTPS listener on :443"
            echo "    Declining keeps devbox HTTP-only; you won't be asked again on subsequent updates."
            echo "    (Run 'devbox dns-install --enable-https' later to opt in.)"
            echo ""
            ans=""
            read -r -p "Run HTTPS upgrade now? [Y/n] " ans || ans=""
            case "$ans" in
                ""|y|Y|yes|YES)
                    # Single source of truth for the upgrade sequence —
                    # see _devbox::run_https_upgrade. Both this prompt and
                    # the standalone `devbox dns-install --enable-https`
                    # command call it, so the user lands in the same
                    # consistent state regardless of how the upgrade got
                    # triggered.
                    _devbox::run_https_upgrade || true
                    ;;
                *)
                    echo "Skipping HTTPS upgrade. Run 'devbox dns-install --enable-https' later if you change your mind."
                    if ! devbox::write_https_field optout true; then
                        echo -e "\033[1;33mWARN: failed persisting opt-out to https.conf; next update may ask again.\033[0m"
                    fi
                    ;;
            esac
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
    # Forward any flags (currently just --purge-ca) through to build.sh,
    # which owns the actual uninstall lifecycle (full_reset + dns-install
    # uninstall + optional CA purge + image / network / config cleanup).
    exec "$DEVBOX_DIR/build.sh" --uninstall "$@"
fi

# --- devbox migrate ----------------------------------------------------------

if [ "$MODE" = "migrate" ]; then
    exec "$DEVBOX_DIR/scripts/migrate-to-bindmount.sh" "$@"
fi

if [ "$MODE" = "migrate-naming" ]; then
    exec "$DEVBOX_DIR/scripts/migrate-naming-ldh.sh" "$@"
fi

# --- devbox dns-install / dns-status / dns-uninstall -------------------------

if [ "$MODE" = "dns-install" ]; then
    # Special-case the HTTPS state changes — they need Traefik + route
    # file orchestration that lives in docker-run.sh (bootstrap_traefik,
    # apply_port_routes). Routing through the orchestration helpers makes
    # the standalone `devbox dns-install --enable-https` end in the same
    # consistent state as the `devbox update` prompt path. The default DNS
    # resolver setup still execs through unchanged.
    case " $* " in
        *' --enable-https '*)
            _devbox::run_https_upgrade
            exit $?
            ;;
        *' --disable-https '*)
            _devbox::run_https_downgrade
            exit $?
            ;;
    esac
    exec "$DEVBOX_DIR/scripts/dns-install.sh" install "$@"
fi

if [ "$MODE" = "dns-status" ]; then
    exec "$DEVBOX_DIR/scripts/dns-install.sh" status "$@"
fi

if [ "$MODE" = "dns-uninstall" ]; then
    exec "$DEVBOX_DIR/scripts/dns-install.sh" uninstall "$@"
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
    running=$(docker ps --filter "name=^devbox-" --format '{{.Names}}' | filter_user_containers)
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
    scheme="$(devbox::url_scheme)"
    while IFS= read -r container; do
        [ -z "$container" ] && continue
        local_project="${container#devbox-}"
        echo "  ${scheme}://$(devbox::route_host_display "$local_project" "$PORT_NUM") → ${container}:${PORT_NUM}"
    done <<< "$running"
    exit 0
fi

# --- devbox ports ------------------------------------------------------------

if [ "$MODE" = "ports" ]; then
    PORTS_SHOW_ALL=false
    PORTS_SHOW_EXTERNAL=false
    for arg in "$@"; do
        case "$arg" in
            --all)      PORTS_SHOW_ALL=true ;;
            --external) PORTS_SHOW_EXTERNAL=true ;;
            -h|--help)
                echo "Usage: devbox ports [--all] [--external]"
                echo "  --all       Include stopped containers and skip the listening filter."
                echo "  --external  Show the external sslip.io URL alongside the active URL."
                exit 0
                ;;
            *) echo "Unknown flag: $arg" >&2; exit 2 ;;
        esac
    done

    if [ ! -d "$TRAEFIK_CONFIG_DIR" ] || [ -z "$(ls -A "$TRAEFIK_CONFIG_DIR" 2>/dev/null)" ]; then
        echo "No active port routes."
        exit 0
    fi

    # Bucket registered route filenames by container. Filename format is
    # `<container>-<port>.yml` (see apply_port_routes); split off the
    # trailing -<port>.
    declare -A PORTS_BY_CONTAINER=()
    for f in "$TRAEFIK_CONFIG_DIR"/*.yml; do
        [ -f "$f" ] || continue
        base="$(basename "$f" .yml)"
        port="${base##*-}"
        container="${base%-*}"
        { [ -n "$container" ] && [ -n "$port" ]; } || continue
        PORTS_BY_CONTAINER["$container"]+="$port "
    done

    if [ "${#PORTS_BY_CONTAINER[@]}" -eq 0 ]; then
        echo "No active port routes."
        exit 0
    fi

    any_output=false
    scheme="$(devbox::url_scheme)"
    for container in $(printf '%s\n' "${!PORTS_BY_CONTAINER[@]}" | sort); do
        running=false
        if docker ps --filter "name=^${container}$" --format '{{.ID}}' | grep -q .; then
            running=true
        fi
        if [ "$running" = false ] && [ "$PORTS_SHOW_ALL" = false ]; then
            continue
        fi

        # shellcheck disable=SC2206  # intentional word-split: space-joined ports
        routed_ports=(${PORTS_BY_CONTAINER[$container]})
        mapfile -t routed_ports < <(printf '%s\n' "${routed_ports[@]}" | sort -un)

        probe_failed=false
        if [ "$running" = true ] && [ "$PORTS_SHOW_ALL" = false ]; then
            if listening_output=$(list_listening_ports_in_container "$container"); then
                if [ -n "$listening_output" ]; then
                    mapfile -t listening_ports <<< "$listening_output"
                    declare -A listen_set=()
                    for p in "${listening_ports[@]}"; do listen_set["$p"]=1; done
                    filtered=()
                    for p in "${routed_ports[@]}"; do
                        [ "${listen_set[$p]:-0}" = 1 ] && filtered+=("$p")
                    done
                    routed_ports=("${filtered[@]}")
                    unset listen_set
                else
                    # Probe succeeded, container has zero LISTEN ports.
                    # Hide the empty group so the default view stays honest
                    # about "nothing reachable right now".
                    routed_ports=()
                fi
            else
                # Probe failed (docker exec hung/erroreded). Falling back
                # to "show all registered routes" so we never silently
                # suppress URLs the user might still reach — the header is
                # annotated below so the listing's unfiltered status is
                # visible.
                probe_failed=true
            fi
        fi

        [ "${#routed_ports[@]}" -eq 0 ] && continue

        any_output=true
        echo
        if [ "$running" = false ]; then
            echo "=== ${container} (not running) ==="
        elif [ "$probe_failed" = true ]; then
            echo "=== ${container} (probe failed — listening filter skipped) ==="
        else
            echo "=== ${container} ==="
        fi

        project="${container#devbox-}"
        {
            if [ "$PORTS_SHOW_EXTERNAL" = true ]; then
                printf 'PORT\tURL\tEXTERNAL URL\n'
            else
                printf 'PORT\tURL\n'
            fi
            for p in "${routed_ports[@]}"; do
                local_url="${scheme}://$(devbox::route_host_display "$project" "$p")"
                if [ "$PORTS_SHOW_EXTERNAL" = true ]; then
                    ext_url="${scheme}://${p}.${project}.127.0.0.1.$(devbox::external_provider)"
                    printf '%s\t%s\t%s\n' "$p" "$local_url" "$ext_url"
                else
                    printf '%s\t%s\n' "$p" "$local_url"
                fi
            done
        } | column -t -s "$(printf '\t')"
    done

    if [ "$any_output" = false ]; then
        if [ "$PORTS_SHOW_ALL" = false ]; then
            echo "No listening ports on running devbox containers."
            echo "Use 'devbox ports --all' to list every registered route."
        else
            echo "No active port routes."
        fi
    fi
    exit 0
fi

# --- devbox connect <target> <port> [local-port] [--from source] -------------

if [ "$MODE" = "connect" ]; then
    if [ "$#" -eq 0 ]; then
        running="$(list_devbox_container_names)"
        if [ -z "$running" ]; then
            echo "No running devbox containers." >&2
            exit 1
        fi

        SOURCE_CONTAINER=$(printf '%s\n' "$running" | picker::one --prompt "Source devbox: ") || exit 1
        SOURCE_PROJECT="${SOURCE_CONTAINER#devbox-}"

        target_candidates=$(printf '%s\n' "$running" | grep -vx "$SOURCE_CONTAINER" || true)
        if [ -z "$target_candidates" ]; then
            echo "No other running devbox containers to connect." >&2
            exit 1
        fi

        TARGET_CONTAINERS=$(printf '%s\n' "$target_candidates" | picker::many --prompt "Target devboxes: ") || exit 1

        service_rows=""
        while IFS= read -r target_container; do
            [ -n "$target_container" ] || continue
            discovered=$(discover_published_tcp_services "$target_container")
            [ -n "$discovered" ] && service_rows=$(printf '%s\n%s' "$service_rows" "$discovered")
        done <<< "$TARGET_CONTAINERS"
        service_rows=$(printf '%s\n' "$service_rows" | grep -v '^$' | sort -u || true)

        if [ -z "$service_rows" ]; then
            echo "No published TCP ports found in selected target devboxes." >&2
            echo "Only compose services with 'ports:' can be connected across devboxes." >&2
            exit 1
        fi

        service_choices=$(while IFS=$'\t' read -r target_project _target_container inner_name host_port private_port; do
            printf '%s / %s  %s->%s/tcp\n' \
                "$target_project" "$inner_name" "$host_port" "$private_port"
        done <<< "$service_rows")

        SELECTED_SERVICES=$(printf '%s\n' "$service_choices" | picker::many --prompt "Services to connect: ") || exit 1

        mkdir -p "$CONNECT_CONFIG_DIR"
        config_file="$(connection_config_file "$SOURCE_PROJECT")"
        touch "$config_file"

        echo "Connections for ${SOURCE_CONTAINER}:"
        while IFS= read -r display; do
            [ -n "${display:-}" ] || continue
            matched=$(while IFS=$'\t' read -r row_target_project row_target_container row_inner_name row_host_port row_private_port; do
                row_display=$(printf '%s / %s  %s->%s/tcp' "$row_target_project" "$row_inner_name" "$row_host_port" "$row_private_port")
                if [ "$row_display" = "$display" ]; then
                    printf '%s\t%s\t%s\t%s\t%s\n' "$row_target_project" "$row_target_container" "$row_inner_name" "$row_host_port" "$row_private_port"
                    break
                fi
            done <<< "$service_rows")
            [ -n "$matched" ] || continue
            IFS=$'\t' read -r target_project target_container inner_name host_port private_port <<< "$matched"
            existing=$(awk -F '\t' -v t="$target_container" -v p="$host_port" '$2 == t && $3 == p { print $4; exit }' "$config_file")
            if [ -n "$existing" ]; then
                local_port="$existing"
            else
                local_port="$(allocate_connection_port "$SOURCE_PROJECT" "$target_container" "$host_port" "$config_file")"
            fi
            alias="${inner_name}.${target_project}.devbox"
            upsert_connection_record "$SOURCE_PROJECT" "$alias" "$target_container" "$host_port" "$local_port"
            start_container_connection "$SOURCE_CONTAINER" "$target_container" "$host_port" "$local_port" "$alias"
            printf '  %-32s 10.0.2.2:%s -> %s:%s\n' "${inner_name}.${target_project}.devbox" "$local_port" "$target_container" "$host_port"
        done <<< "$SELECTED_SERVICES"

        echo "Persisted in: $config_file"
        exit 0
    fi

    SOURCE_TOKEN=""
    POSITIONAL=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --from)
                shift
                SOURCE_TOKEN="${1:-}"
                [ -n "$SOURCE_TOKEN" ] || { echo "Usage: devbox connect <target> <port> [local-port] [--from source]" >&2; exit 1; }
                ;;
            --from=*)
                SOURCE_TOKEN="${1#--from=}"
                ;;
            -h|--help)
                echo "Usage: devbox connect"
                echo "       devbox connect <target> <port> [local-port] [--from source]"
                echo "Example: devbox connect api 5432"
                echo "Inner Docker containers connect to 10.0.2.2:<local-port>."
                exit 0
                ;;
            *)
                POSITIONAL+=("$1")
                ;;
        esac
        shift || true
    done

    TARGET_TOKEN="${POSITIONAL[0]:-}"
    TARGET_PORT="${POSITIONAL[1]:-}"
    LOCAL_PORT="${POSITIONAL[2]:-}"

    if [ -z "$TARGET_TOKEN" ] || [ -z "$TARGET_PORT" ]; then
        echo "Usage: devbox connect <target> <port> [local-port] [--from source]" >&2
        exit 1
    fi
    if ! [[ "$TARGET_PORT" =~ ^[0-9]+$ ]] || [ "$TARGET_PORT" -lt 1 ] || [ "$TARGET_PORT" -gt 65535 ]; then
        echo "Target port must be a number from 1 to 65535." >&2
        exit 1
    fi
    if [ -n "$LOCAL_PORT" ] && { ! [[ "$LOCAL_PORT" =~ ^[0-9]+$ ]] || [ "$LOCAL_PORT" -lt 1 ] || [ "$LOCAL_PORT" -gt 65535 ]; }; then
        echo "Local port must be a number from 1 to 65535." >&2
        exit 1
    fi

    if [ -n "$SOURCE_TOKEN" ]; then
        devbox::names_from_token "$SOURCE_TOKEN"
    else
        devbox::names_from_path "$(pwd)"
    fi
    SOURCE_PROJECT="$DEVBOX_PROJECT_NAME"
    SOURCE_CONTAINER="$DEVBOX_CONTAINER_NAME"

    devbox::names_from_token "$TARGET_TOKEN"
    TARGET_PROJECT="$DEVBOX_PROJECT_NAME"
    TARGET_CONTAINER="$DEVBOX_CONTAINER_NAME"

    if ! docker ps --filter "name=^${SOURCE_CONTAINER}$" --format '{{.Names}}' | grep -qx "$SOURCE_CONTAINER"; then
        echo "Source container is not running: $SOURCE_CONTAINER" >&2
        echo "Use --from <source> when running outside the source project directory." >&2
        exit 1
    fi
    if ! docker ps --filter "name=^${TARGET_CONTAINER}$" --format '{{.Names}}' | grep -qx "$TARGET_CONTAINER"; then
        echo "Target container is not running: $TARGET_CONTAINER" >&2
        exit 1
    fi

    CONFIG_FILE="$(connection_config_file "$SOURCE_PROJECT")"
    mkdir -p "$CONNECT_CONFIG_DIR"
    touch "$CONFIG_FILE"

    if [ -z "$LOCAL_PORT" ]; then
        existing=$(awk -F '\t' -v t="$TARGET_CONTAINER" -v p="$TARGET_PORT" '$2 == t && $3 == p { print $4; exit }' "$CONFIG_FILE")
        if [ -n "$existing" ]; then
            LOCAL_PORT="$existing"
        else
            LOCAL_PORT="$(allocate_connection_port "$SOURCE_PROJECT" "$TARGET_CONTAINER" "$TARGET_PORT" "$CONFIG_FILE")"
        fi
    fi

    ALIAS="${TARGET_PROJECT}-${TARGET_PORT}"
    upsert_connection_record "$SOURCE_PROJECT" "$ALIAS" "$TARGET_CONTAINER" "$TARGET_PORT" "$LOCAL_PORT"

    start_container_connection "$SOURCE_CONTAINER" "$TARGET_CONTAINER" "$TARGET_PORT" "$LOCAL_PORT" "$ALIAS"

    echo "Connected: ${SOURCE_CONTAINER} -> ${TARGET_CONTAINER}:${TARGET_PORT}"
    echo "Use from inner Docker containers: 10.0.2.2:${LOCAL_PORT}"
    echo "Persisted in: $CONFIG_FILE"
    exit 0
fi

# --- devbox connections ------------------------------------------------------

if [ "$MODE" = "connections" ]; then
    if [ ! -d "$CONNECT_CONFIG_DIR" ] || [ -z "$(ls -A "$CONNECT_CONFIG_DIR" 2>/dev/null)" ]; then
        echo "No devbox connections."
        exit 0
    fi

    printf '%-25s %-28s %-16s %s\n' "SOURCE" "TARGET" "INNER ENDPOINT" "ALIAS"
    for f in "$CONNECT_CONFIG_DIR"/*.tsv; do
        [ -f "$f" ] || continue
        source_project="$(basename "$f" .tsv)"
        while IFS=$'\t' read -r alias target_container target_port local_port; do
            [ -n "${alias:-}" ] || continue
            case "$alias" in \#*) continue ;; esac
            printf '%-25s %-28s %-16s %s\n' \
                "devbox-${source_project}" "${target_container}:${target_port}" "10.0.2.2:${local_port}" "$alias"
        done < "$f"
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
            _devbox::remove_project_https_artifacts "$DEVBOX_PROJECT_NAME"
            stop_traefik_if_idle
            stop_dns_if_idle
            exit 0
        fi
        echo "Container $name is not running." >&2
    fi
    # No argument or container not found → interactive selection
    selected=$(pick_container "Stop container: " "with_all") || exit 1
    if [ "$selected" = "* Stop all" ]; then
        docker ps -a --filter "name=^devbox-" --format '{{.Names}}' | filter_user_containers | while IFS= read -r c; do
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
            _devbox::remove_project_https_artifacts "$proj"
        done
        stop_traefik_if_idle
        stop_dns_if_idle
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
        _devbox::remove_project_https_artifacts "$proj"
        stop_traefik_if_idle
        stop_dns_if_idle
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
    containers=$(docker ps --filter "name=^devbox-" --format '{{.Names}}' | filter_user_containers)
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
        bootstrap_dns
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
        bootstrap_dns
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

# --- Bootstrap Traefik, DNS resolver & devproxy network ---------------------

bootstrap_traefik
bootstrap_dns

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
    -e DOCKERD_ROOTLESS_ROOTLESSKIT_DISABLE_HOST_LOOPBACK=false
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
    scheme="$(devbox::url_scheme)"
    while read -r port _rest; do
        port="${port%%#*}"
        [ -z "$port" ] && continue
        echo "  ${scheme}://$(devbox::route_host_display "$PROJECT_NAME" "$port") → ${CONTAINER_NAME}:${port}"
    done < "$ports_file"
else
    echo "  Set port: devbox port <port>"
fi

# Root-context setup (firewall, gitconfig, host-home symlink, IDE server
# ownership) is handled by the entrypoint on every container start.
docker exec -u node "$CONTAINER_NAME" bash -c \
    '/usr/local/bin/start-rootless-docker.sh && /usr/local/bin/setup-chezmoi.sh && /usr/local/bin/setup-claude.sh'

start_devbox_connections "$CONTAINER_NAME"

# Attach first interactive session
set_tab_title "$PROJECT_NAME"
exec docker exec -it -u node -w "$PROJECT_PATH" "$CONTAINER_NAME" zsh
