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

# Extract ruby-maat version from Gemfile.lock (single source of truth).
# Restrict the match to the GEM section and take only the first hit to avoid
# matching the CHECKSUMS section (which includes a sha256 suffix).
RUBY_MAAT_VERSION=$(sed -n '/^GEM$/,/^$/s/^  *ruby-maat (\(.*\))/\1/p' "${PROJECT_ROOT}/Gemfile.lock" | head -n 1)
if [ -z "${RUBY_MAAT_VERSION}" ]; then
    echo "ERROR: Could not extract ruby-maat version from Gemfile.lock" >&2
    exit 1
fi

# Extract agent-harness version from Gemfile.lock.
# The Dockerfile uses this to install the gem temporarily and read Cursor
# install metadata from the agent-harness install contract.
AGENT_HARNESS_VERSION=$(sed -n '/^GEM$/,/^$/s/^  *agent-harness (\(.*\))/\1/p' "${PROJECT_ROOT}/Gemfile.lock" | head -n 1)
if [ -z "${AGENT_HARNESS_VERSION}" ]; then
    echo "ERROR: Could not extract agent-harness version from Gemfile.lock" >&2
    exit 1
fi

# Extract Claude CLI install contract from agent-harness (single source of truth).
# The helper script outputs key=value pairs; we capture the ones we need.
CLAUDE_CONTRACT=$(bundle exec ruby "${PROJECT_ROOT}/scripts/extract-provider-install-contract.rb" claude)
CLAUDE_INSTALL_COMMAND=$(echo "${CLAUDE_CONTRACT}" | sed -n 's/^INSTALL_COMMAND=//p')
CLAUDE_POST_INSTALL_BINARY_PATH=$(echo "${CLAUDE_CONTRACT}" | sed -n 's/^POST_INSTALL_BINARY_PATH=//p')

if [ -z "${CLAUDE_INSTALL_COMMAND}" ]; then
    echo "ERROR: Could not extract Claude install command from agent-harness" >&2
    exit 1
fi

if [ -z "${CLAUDE_POST_INSTALL_BINARY_PATH}" ]; then
    echo "ERROR: Could not extract Claude post-install binary path from agent-harness" >&2
    exit 1
fi

echo "Building agent container image..."
echo "  Image: ${FULL_IMAGE}"
echo "  Context: ${PROJECT_ROOT}/docker/agent"
echo "  ruby-maat: ${RUBY_MAAT_VERSION}"
echo "  agent-harness: ${AGENT_HARNESS_VERSION}"
echo "  claude-install: via agent-harness contract"

docker build \
    -t "${FULL_IMAGE}" \
    -f "${PROJECT_ROOT}/docker/agent/Dockerfile" \
    --build-arg "RUBY_MAAT_VERSION=${RUBY_MAAT_VERSION}" \
    --build-arg "AGENT_HARNESS_VERSION=${AGENT_HARNESS_VERSION}" \
    --build-arg "CLAUDE_INSTALL_COMMAND=${CLAUDE_INSTALL_COMMAND}" \
    --build-arg "CLAUDE_POST_INSTALL_BINARY_PATH=${CLAUDE_POST_INSTALL_BINARY_PATH}" \
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
