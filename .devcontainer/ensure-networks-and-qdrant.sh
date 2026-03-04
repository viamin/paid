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
docker compose -f "$COMPOSE_FILE" up -d qdrant

# Create paid_agent if it doesn't exist, matching docker-compose.yml settings
# and applying the same Compose labels as paid_internal so Compose does not
# later report a label mismatch for this network.
if ! docker network inspect paid_agent >/dev/null 2>&1; then
  echo "Creating paid_agent network..."

  create_args=(
    paid_agent
    --driver bridge
    --internal
    --subnet 172.28.0.0/16
    --opt com.docker.network.bridge.enable_ip_masquerade=false
  )

  # Derive Compose labels from the already-Compose-created paid_internal network
  for label in com.docker.compose.project com.docker.compose.version \
               com.docker.compose.project.config_files com.docker.compose.project.working_dir; do
    val=$(docker network inspect paid_internal --format "{{index .Labels \"$label\"}}" 2>/dev/null || echo "")
    if [[ -n "$val" ]]; then
      create_args+=(--label "${label}=${val}")
    fi
  done
  create_args+=(--label "com.docker.compose.network=paid_agent")

  docker network create "${create_args[@]}"
fi

# Connect the devcontainer to both networks if not already connected
for net in paid_internal paid_agent; do
  if ! docker network inspect "$net" --format '{{range .Containers}}{{.Name}}{{end}}' | grep -q "$CONTAINER_NAME"; then
    echo "Connecting devcontainer to $net..."
    docker network connect --alias web --alias paid-proxy "$net" "$(hostname)"
  fi
done

echo "Networks and Qdrant ready."
