#!/bin/bash
# Build script for the agent container image
#
# Usage:
#   ./scripts/build-agent-image.sh              # Build image locally
#   IMAGE_TAG=v1.0.0 ./scripts/build-agent-image.sh  # Build with custom tag
#   PUSH=true ./scripts/build-agent-image.sh    # Build and push to registry

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

IMAGE_NAME="${IMAGE_NAME:-paid-agent}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

echo "Building agent container image..."
echo "  Image: ${FULL_IMAGE}"
echo "  Context: ${PROJECT_ROOT}/docker/agent"

docker build \
    -t "${FULL_IMAGE}" \
    -f "${PROJECT_ROOT}/docker/agent/Dockerfile" \
    "${PROJECT_ROOT}/docker/agent/"

echo ""
echo "Image built successfully: ${FULL_IMAGE}"
echo ""

# Show image size
IMAGE_SIZE=$(docker images --format "{{.Size}}" "${FULL_IMAGE}")
echo "Image size: ${IMAGE_SIZE}"

# Optionally push to registry
if [ "${PUSH}" = "true" ]; then
    echo ""
    echo "Pushing image to registry..."
    docker push "${FULL_IMAGE}"
    echo "Image pushed: ${FULL_IMAGE}"
fi
