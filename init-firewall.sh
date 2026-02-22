#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# Devbox Firewall - Based on Claude Code default-deny with extensions
# =============================================================================

# 1. Extract Docker DNS info BEFORE any flushing
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# Flush existing rules and delete existing ipsets
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# 2. Selectively restore ONLY internal Docker DNS resolution
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules to restore"
fi

# First allow DNS and localhost before any restrictions
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Create ipset with CIDR support
ipset create allowed-domains hash:net

# Fetch GitHub meta information and aggregate + add their IP ranges
echo "Fetching GitHub IP ranges..."
gh_ranges=$(curl -s https://api.github.com/meta)
if [ -z "$gh_ranges" ]; then
    echo "ERROR: Failed to fetch GitHub IP ranges"
    exit 1
fi

if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
    echo "ERROR: GitHub API response missing required fields"
    exit 1
fi

echo "Processing GitHub IPs..."
while read -r cidr; do
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "ERROR: Invalid CIDR range from GitHub meta: $cidr"
        exit 1
    fi
    echo "Adding GitHub range $cidr"
    ipset add allowed-domains "$cidr"
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q)

# =============================================================================
# Allowed domains — all resolved dynamically via dnsmasq
# =============================================================================
# dnsmasq ipset= directive adds resolved IPs to the ipset at DNS lookup time.
# This handles CDN IP rotation, wildcard subdomains, and everything else
# without static dig resolution or hardcoded CIDR workarounds.

# Base domains (Claude Code + devbox)
DNSMASQ_DOMAINS=(
    "registry.npmjs.org"
    "api.anthropic.com"
    "platform.claude.com"
    "claude.ai"
    "sentry.io"
    "statsig.anthropic.com"
    "statsig.com"
    "marketplace.visualstudio.com"
    "vscode.blob.core.windows.net"
    "update.code.visualstudio.com"
    # Docker Hub (rootless DinD)
    "registry-1.docker.io"
    "auth.docker.io"
    "production.cloudflare.docker.com"
    "docker.io"
    "docker-images-prod.6aa30f8b08e16409b46e0173d6de2f56.r2.cloudflarestorage.com"
)

# Extra domains from config file
EXTRA_DOMAINS_FILE="/usr/local/etc/devbox-extra-domains.conf"
if [ -f "$EXTRA_DOMAINS_FILE" ]; then
    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/#.*//' | xargs)
        [ -n "$line" ] && DNSMASQ_DOMAINS+=("$line")
    done < "$EXTRA_DOMAINS_FILE"
fi

# Extra domains from environment variable (comma-separated)
if [ -n "${DEVBOX_EXTRA_DOMAINS:-}" ]; then
    IFS=',' read -ra ENV_DOMAINS <<< "$DEVBOX_EXTRA_DOMAINS"
    for domain in "${ENV_DOMAINS[@]}"; do
        domain=$(echo "$domain" | xargs)
        [ -n "$domain" ] && DNSMASQ_DOMAINS+=("$domain")
    done
fi

# Get host IP from default route
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP"
    exit 1
fi

HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
echo "Host network detected as: $HOST_NETWORK"

# Set up remaining iptables rules
iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# Set default policies to DROP
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Allow established connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow only outbound traffic to allowed domains
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# Reject all other outbound traffic for immediate feedback
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# =============================================================================
# dnsmasq — dynamic DNS-to-ipset resolution for all allowed domains
# =============================================================================
echo "Configuring dnsmasq for ${#DNSMASQ_DOMAINS[@]} domain(s)..."

# Save Docker's upstream DNS before overwriting resolv.conf
UPSTREAM_DNS=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf)

# Generate dnsmasq config
mkdir -p /etc/dnsmasq.d
cat > /etc/dnsmasq.d/devbox-firewall.conf <<DNSCONF
# Devbox firewall — dynamic DNS-to-ipset resolution
bind-interfaces
listen-address=127.0.0.1
port=53
no-resolv
server=${UPSTREAM_DNS}
DNSCONF

for domain in "${DNSMASQ_DOMAINS[@]}"; do
    # Wildcard *.example.com → ipset rule for /example.com/ (matches all subdomains)
    # Regular example.com  → ipset rule for /example.com/ (matches exact + subdomains)
    if [[ "$domain" == \*.* ]]; then
        base="${domain#\*.}"
        echo "ipset=/${base}/allowed-domains" >> /etc/dnsmasq.d/devbox-firewall.conf
        echo "  Wildcard: ${domain} → dnsmasq ipset for ${base}"
    else
        echo "ipset=/${domain}/allowed-domains" >> /etc/dnsmasq.d/devbox-firewall.conf
        echo "  Domain: ${domain} → dnsmasq ipset"
    fi
done

# Start dnsmasq
dnsmasq --conf-dir=/etc/dnsmasq.d --keep-in-foreground &
DNSMASQ_PID=$!
sleep 0.5

if kill -0 "$DNSMASQ_PID" 2>/dev/null; then
    echo "dnsmasq started (PID $DNSMASQ_PID)"
    # Redirect container DNS through dnsmasq
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
else
    echo "ERROR: dnsmasq failed to start"
    wait "$DNSMASQ_PID" || true
    exit 1
fi

echo "Firewall configuration complete"
echo "Verifying firewall rules..."
if curl --connect-timeout 5 https://www.google.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://www.google.com"
    exit 1
else
    echo "Firewall verification passed - unable to reach https://www.google.com as expected"
fi

if ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://api.github.com"
    exit 1
else
    echo "Firewall verification passed - able to reach https://api.github.com as expected"
fi
