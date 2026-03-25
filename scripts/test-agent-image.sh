#!/bin/bash
# Test script for verifying the agent container image
#
# Usage:
#   ./scripts/test-agent-image.sh              # Test default image
#   IMAGE_NAME=myregistry/paid-agent ./scripts/test-agent-image.sh  # Test custom image

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE_NAME="${IMAGE_NAME:-paid-agent}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

echo "Testing agent container image: ${FULL_IMAGE}"
echo "============================================="
echo ""

# Test that the image exists
if ! docker image inspect "${FULL_IMAGE}" > /dev/null 2>&1; then
    echo "Error: Image '${FULL_IMAGE}' not found. Build it first with:"
    echo "  ./scripts/build-agent-image.sh"
    exit 1
fi

# Run tests inside the container.
# The inner script is mounted read-only so it can be linted independently by shellcheck
# and to avoid complex quoting/escaping issues that arise with large bash -c strings.
docker run --rm \
    -v "${SCRIPT_DIR}/test-agent-image-inner.sh:/tmp/test.sh:ro" \
    "${FULL_IMAGE}" bash /tmp/test.sh

echo ""
echo "============================================="
echo "Image test completed successfully!"
