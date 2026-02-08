#!/bin/bash
# scripts/setup-agent-network.sh
#
# Configures iptables rules to restrict outbound traffic from the
# paid_agent Docker network. Only allowed destinations:
#   - Secrets proxy (for LLM API access)
#   - GitHub (for git operations)
#   - DNS (for hostname resolution)
#
# Prerequisites:
#   - Docker network "paid_agent" must already exist
#   - Must be run as root (iptables requires privileges)
#
# Usage:
#   sudo scripts/setup-agent-network.sh
#
# Environment variables:
#   SECRETS_PROXY_PORT - Port of the secrets proxy (default: 3001)
#   DRY_RUN            - Set to "1" to print rules without applying (default: "")

set -euo pipefail

# Network name (must match docker-compose.yml)
NETWORK_NAME="paid_agent"

# Secrets proxy port
SECRETS_PROXY_PORT="${SECRETS_PROXY_PORT:-3001}"

# Dry run mode
DRY_RUN="${DRY_RUN:-}"

# GitHub IP ranges (from https://api.github.com/meta)
# These should be refreshed periodically via NetworkPolicy.fetch_github_ips
GITHUB_IPS=(
    "140.82.112.0/20"
    "143.55.64.0/20"
    "185.199.108.0/22"
    "192.30.252.0/22"
    "20.201.28.0/24"
)

# Chain name for our rules
CHAIN_NAME="PAID_AGENT"

run_iptables() {
    if [ -n "$DRY_RUN" ]; then
        echo "[DRY RUN] iptables $*"
    else
        iptables "$@"
    fi
}

echo "Setting up iptables rules for agent network '${NETWORK_NAME}'..."

# Verify network exists
if ! docker network inspect "${NETWORK_NAME}" > /dev/null 2>&1; then
    echo "ERROR: Docker network '${NETWORK_NAME}' does not exist."
    echo "Create it with: docker compose up (or docker network create --internal ${NETWORK_NAME})"
    exit 1
fi

# Get the bridge interface for our network
NETWORK_ID=$(docker network inspect "${NETWORK_NAME}" -f '{{.Id}}' | cut -c1-12)
BRIDGE_IF="br-${NETWORK_ID}"

echo "Bridge interface: ${BRIDGE_IF}"

# Get the gateway IP (used as secrets proxy address since proxy runs on host)
GATEWAY_IP=$(docker network inspect "${NETWORK_NAME}" -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}')
if [ -z "$GATEWAY_IP" ]; then
    GATEWAY_IP="172.28.0.1"
    echo "WARNING: Could not detect gateway IP, using default: ${GATEWAY_IP}"
fi

echo "Gateway (proxy) IP: ${GATEWAY_IP}"

# Clean up existing rules
echo "Cleaning up existing rules..."
run_iptables -D FORWARD -i "${BRIDGE_IF}" -j "${CHAIN_NAME}" 2>/dev/null || true
run_iptables -F "${CHAIN_NAME}" 2>/dev/null || true
run_iptables -X "${CHAIN_NAME}" 2>/dev/null || true

# Create new chain
echo "Creating iptables chain '${CHAIN_NAME}'..."
run_iptables -N "${CHAIN_NAME}"

# Allow established/related connections (for responses to allowed requests)
run_iptables -A "${CHAIN_NAME}" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow connections to secrets proxy (on gateway/host)
echo "Allowing secrets proxy (${GATEWAY_IP}:${SECRETS_PROXY_PORT})..."
run_iptables -A "${CHAIN_NAME}" -d "${GATEWAY_IP}" -p tcp --dport "${SECRETS_PROXY_PORT}" -j ACCEPT

# Allow connections to GitHub
echo "Allowing GitHub IP ranges..."
for ip in "${GITHUB_IPS[@]}"; do
    run_iptables -A "${CHAIN_NAME}" -d "${ip}" -p tcp --dport 443 -j ACCEPT
    run_iptables -A "${CHAIN_NAME}" -d "${ip}" -p tcp --dport 22 -j ACCEPT
done

# Allow DNS (required for hostname resolution)
echo "Allowing DNS..."
run_iptables -A "${CHAIN_NAME}" -p udp --dport 53 -j ACCEPT
run_iptables -A "${CHAIN_NAME}" -p tcp --dport 53 -j ACCEPT

# Log dropped packets for debugging/auditing
run_iptables -A "${CHAIN_NAME}" -j LOG --log-prefix "PAID_AGENT_BLOCK: " --log-level 4

# Drop everything else
run_iptables -A "${CHAIN_NAME}" -j DROP

# Apply chain to forward traffic from agent network
run_iptables -I FORWARD -i "${BRIDGE_IF}" -j "${CHAIN_NAME}"

echo "Network rules configured successfully for '${NETWORK_NAME}'."
echo ""
echo "Allowed traffic:"
echo "  - Secrets proxy: ${GATEWAY_IP}:${SECRETS_PROXY_PORT}"
echo "  - GitHub: HTTPS (443) and SSH (22)"
echo "  - DNS: UDP/TCP port 53"
echo "  - All other outbound traffic: BLOCKED (logged as PAID_AGENT_BLOCK)"
