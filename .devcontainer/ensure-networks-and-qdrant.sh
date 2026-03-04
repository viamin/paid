#!/bin/bash
# Ensure Docker networks exist and start Qdrant for the devcontainer.
#
# - Starts Qdrant via Compose so paid_internal gets proper Compose labels.
# - Creates paid_agent with the same settings as docker-compose.yml
#   (internal, restricted subnet, no IP masquerade) if it doesn't exist.
# - Connects the devcontainer to both networks with aliases.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/docker-compose.yml"

# Preflight: if paid_internal exists without Compose labels, it will cause
# a label mismatch error when Compose tries to use it. Detect and fix this.
if docker network inspect paid_internal >/dev/null 2>&1; then
  existing_label="$(docker network inspect paid_internal --format '{{ index .Labels "com.docker.compose.project" }}' 2>/dev/null || true)"
  if [[ -z "$existing_label" || "$existing_label" == "<no value>" ]]; then
    echo "Removing stale paid_internal network (missing Compose labels)..."
    docker network disconnect paid_internal "$(hostname)" 2>/dev/null || true
    if ! docker network rm paid_internal 2>/dev/null; then
      echo "ERROR: Failed to remove stale paid_internal network." >&2
      echo "It may still be attached to other containers. Stop/disconnect them and retry." >&2
      exit 1
    fi
  fi
fi

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
    if [[ -n "$val" && "$val" != "<no value>" ]]; then
      create_args+=(--label "${label}=${val}")
    fi
  done
  create_args+=(--label "com.docker.compose.network=paid_agent")

  docker network create "${create_args[@]}"
fi

# Connect the devcontainer to both networks if not already connected.
# Resolve container name from hostname (container ID) for consistent checking.
container_id="$(hostname)"
container_name="$(docker inspect --format '{{.Name}}' "$container_id" 2>/dev/null | sed 's|^/||' || true)"
target_container="${container_name:-$container_id}"

for net in paid_internal paid_agent; do
  if ! docker network inspect "$net" --format '{{range .Containers}}{{.Name}}{{end}}' | grep -q "$target_container"; then
    echo "Connecting devcontainer to $net..."
    docker network connect --alias web --alias paid-proxy "$net" "$target_container"
  fi
done

echo "Networks and Qdrant ready."
