#!/bin/bash
# Test script for verifying the agent container image
#
# Usage:
#   ./scripts/test-agent-image.sh              # Test default image
#   IMAGE_NAME=myregistry/paid-agent ./scripts/test-agent-image.sh  # Test custom image

set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-paid-agent}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INNER_SCRIPT="${SCRIPT_DIR}/test-agent-image-inner.sh"

echo "Testing agent container image: ${FULL_IMAGE}"
echo "============================================="
echo ""

# Test that the image exists
if ! docker image inspect "${FULL_IMAGE}" > /dev/null 2>&1; then
    echo "Error: Image '${FULL_IMAGE}' not found. Build it first with:"
    echo "  ./scripts/build-agent-image.sh"
    exit 1
fi

if [ ! -f "${INNER_SCRIPT}" ]; then
    echo "Error: inner test script not found: ${INNER_SCRIPT}"
    exit 1
fi

# Run tests inside the container
docker run --rm \
    -v "${INNER_SCRIPT}:/tmp/test-agent-image-inner.sh:ro" \
    "${FULL_IMAGE}" \
    bash /tmp/test-agent-image-inner.sh

echo ""
echo "============================================="
echo "Image test completed successfully!"
