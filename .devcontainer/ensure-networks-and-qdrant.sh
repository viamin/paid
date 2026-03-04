#!/bin/bash
# Ensure Docker networks exist and start Qdrant for the devcontainer.
#
# - Starts Qdrant via Compose so paid_internal gets proper Compose labels.
# - Creates paid_agent with the same settings as docker-compose.yml
#   (internal, restricted subnet, no IP masquerade) if it doesn't exist.
# - Connects the devcontainer to both networks with aliases.

set -euo pipefail

COMPOSE_FILE="/workspaces/paid/docker-compose.yml"
CONTAINER_NAME="paid-rails-app-1"

# Start Qdrant (creates paid_internal with proper Compose labels)
echo "Starting Qdrant..."
docker compose -f "$COMPOSE_FILE" up qdrant -d

# Create paid_agent if it doesn't exist, matching docker-compose.yml settings
if ! docker network inspect paid_agent >/dev/null 2>&1; then
  echo "Creating paid_agent network..."
  docker network create paid_agent \
    --driver bridge \
    --internal \
    --subnet 172.28.0.0/16 \
    --opt com.docker.network.bridge.enable_ip_masquerade=false
fi

# Connect the devcontainer to both networks if not already connected
for net in paid_internal paid_agent; do
  if ! docker network inspect "$net" --format '{{range .Containers}}{{.Name}}{{end}}' | grep -q "$CONTAINER_NAME"; then
    echo "Connecting devcontainer to $net..."
    docker network connect --alias web --alias paid-proxy "$net" "$(hostname)"
  fi
done

echo "Networks and Qdrant ready."
