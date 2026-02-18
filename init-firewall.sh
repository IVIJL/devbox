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
# Resolve and add allowed domains
# =============================================================================

# Base domains (Claude Code + devbox)
BASE_DOMAINS=(
    "registry.npmjs.org"
    "api.anthropic.com"
    "sentry.io"
    "statsig.anthropic.com"
    "statsig.com"
    "marketplace.visualstudio.com"
    "vscode.blob.core.windows.net"
    "update.code.visualstudio.com"
    "rep.gaiagroup.cz"
    # Docker Hub (rootless DinD) - registry API on AWS
    "registry-1.docker.io"
    "auth.docker.io"
    "production.cloudflare.docker.com"
    "docker.io"
)

# Cloudflare CDN ranges used by Docker Hub blob storage and npm registry.
# Docker Hub redirects layer downloads to Cloudflare, and IPs rotate across
# these ranges. Individual DNS resolution is not sufficient for CDN services.
# 104.16.0.0/14 covers 104.16-19.x.x (npm, Docker auth, Docker prod cloudflare)
# 172.64.0.0/13 covers 172.64-71.x.x (Docker Hub blob downloads)
CLOUDFLARE_CDN_RANGES=(
    "104.16.0.0/13"
    "172.64.0.0/13"
)
for cidr in "${CLOUDFLARE_CDN_RANGES[@]}"; do
    echo "Adding Cloudflare CDN range $cidr (Docker Hub / npm)"
    ipset add allowed-domains "$cidr"
done

# Extra domains from config file
EXTRA_DOMAINS_FILE="/usr/local/etc/devbox-extra-domains.conf"
if [ -f "$EXTRA_DOMAINS_FILE" ]; then
    while IFS= read -r line; do
        # Skip comments and empty lines
        line=$(echo "$line" | sed 's/#.*//' | xargs)
        [ -n "$line" ] && BASE_DOMAINS+=("$line")
    done < "$EXTRA_DOMAINS_FILE"
fi

# Extra domains from environment variable (comma-separated)
if [ -n "${DEVBOX_EXTRA_DOMAINS:-}" ]; then
    IFS=',' read -ra ENV_DOMAINS <<< "$DEVBOX_EXTRA_DOMAINS"
    for domain in "${ENV_DOMAINS[@]}"; do
        domain=$(echo "$domain" | xargs)
        [ -n "$domain" ] && BASE_DOMAINS+=("$domain")
    done
fi

# Resolve all domains
for domain in "${BASE_DOMAINS[@]}"; do
    echo "Resolving $domain..."
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
    if [ -z "$ips" ]; then
        echo "WARNING: Failed to resolve $domain (skipping)"
        continue
    fi

    while read -r ip; do
        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "ERROR: Invalid IP from DNS for $domain: $ip"
            exit 1
        fi
        echo "Adding $ip for $domain"
        ipset add allowed-domains "$ip" 2>/dev/null || true
    done < <(echo "$ips")
done

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
