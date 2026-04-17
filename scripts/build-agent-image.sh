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

# Extract Gemini CLI install command from agent-harness (single source of truth).
# The install contract is defined by the agent-harness gem, so Paid does not
# hardcode the package name or version.
GEMINI_CLI_INSTALL_COMMAND=$(cd "${PROJECT_ROOT}" && bundle exec ruby -e '
  require "agent_harness"
  contract = AgentHarness::Providers::Gemini.install_contract
  puts contract[:install_command_string]
')
if [ -z "${GEMINI_CLI_INSTALL_COMMAND}" ]; then
    echo "ERROR: Could not extract Gemini CLI install command from agent-harness" >&2
    exit 1
fi

echo "Building agent container image..."
echo "  Image: ${FULL_IMAGE}"
echo "  Context: ${PROJECT_ROOT}/docker/agent"
echo "  ruby-maat: ${RUBY_MAAT_VERSION}"
echo "  gemini-cli: ${GEMINI_CLI_INSTALL_COMMAND}"

docker build \
    -t "${FULL_IMAGE}" \
    -f "${PROJECT_ROOT}/docker/agent/Dockerfile" \
    --build-arg "RUBY_MAAT_VERSION=${RUBY_MAAT_VERSION}" \
    --build-arg "GEMINI_CLI_INSTALL_COMMAND=${GEMINI_CLI_INSTALL_COMMAND}" \
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
