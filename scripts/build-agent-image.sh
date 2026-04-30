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

DOCKER_BUILD_ENV=()
TEMP_DOCKER_CONFIG=""
docker_config_path="${DOCKER_CONFIG:-${HOME}/.docker}/config.json"

# VS Code devcontainers inject a short-lived Docker credential helper into
# ~/.docker/config.json. Nested docker builds can outlive that helper and then
# fail while resolving public images with:
#   error getting credentials - err: exit status 255
# The agent image only pulls public images, so bypass that helper for this build.
if [ -f "${docker_config_path}" ] && grep -q '"credsStore"[[:space:]]*:[[:space:]]*"dev-containers-' "${docker_config_path}"; then
    TEMP_DOCKER_CONFIG="$(mktemp -d)"
    DOCKER_BUILD_ENV=(env DOCKER_CONFIG="${TEMP_DOCKER_CONFIG}")
    trap 'rm -rf "${TEMP_DOCKER_CONFIG}"' EXIT
fi

# Extract ruby-maat version from Gemfile.lock (single source of truth).
# Restrict the match to the GEM section and take only the first hit to avoid
# matching the CHECKSUMS section (which includes a sha256 suffix).
RUBY_MAAT_VERSION=$(sed -n '/^GEM$/,/^$/s/^  *ruby-maat (\(.*\))/\1/p' "${PROJECT_ROOT}/Gemfile.lock" | head -n 1)
if [ -z "${RUBY_MAAT_VERSION}" ]; then
    echo "ERROR: Could not extract ruby-maat version from Gemfile.lock" >&2
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

# Extract Cursor CLI install contract from agent-harness (single source of truth).
# Uses the pinned artifact URL + checksum (more stable than the install script).
CURSOR_CONTRACT=$(bundle exec ruby "${PROJECT_ROOT}/scripts/extract-provider-install-contract.rb" cursor)
CURSOR_ARTIFACT_URL=$(echo "${CURSOR_CONTRACT}" | sed -n 's/^ARTIFACT_URL=//p')
CURSOR_ARTIFACT_SHA256=$(echo "${CURSOR_CONTRACT}" | sed -n 's/^ARTIFACT_SHA256=//p')
CURSOR_BINARY_NAME=$(echo "${CURSOR_CONTRACT}" | sed -n 's/^BINARY_NAME=//p')
CURSOR_GLOBAL_PATH=$(echo "${CURSOR_CONTRACT}" | sed -n 's/^GLOBAL_PATH=//p')

if [ -z "${CURSOR_ARTIFACT_URL}" ]; then
    echo "ERROR: Could not extract Cursor artifact URL from agent-harness" >&2
    exit 1
fi

if [ -z "${CURSOR_ARTIFACT_SHA256}" ]; then
    echo "ERROR: Could not extract Cursor artifact SHA256 from agent-harness" >&2
    exit 1
fi

if [ -z "${CURSOR_BINARY_NAME}" ]; then
    echo "ERROR: Could not extract Cursor binary name from agent-harness" >&2
    exit 1
fi

if [ -z "${CURSOR_GLOBAL_PATH}" ]; then
    echo "ERROR: Could not extract Cursor global path from agent-harness" >&2
    exit 1
fi

# Extract Codex CLI package from agent-harness installation contract.
# agent-harness owns the supported Codex CLI version; Paid consumes it at build time.
CODEX_CONTRACT=$(bundle exec ruby "${PROJECT_ROOT}/scripts/extract-provider-install-contract.rb" codex)
CODEX_PACKAGE=$(echo "${CODEX_CONTRACT}" | sed -n 's/^PACKAGE=//p')
if [ -z "${CODEX_PACKAGE}" ]; then
    echo "ERROR: Could not extract Codex package from agent-harness" >&2
    exit 1
fi

# Extract OpenCode CLI package from agent-harness installation contract.
# agent-harness owns the supported OpenCode CLI version; Paid consumes it at build time.
OPENCODE_CONTRACT=$(bundle exec ruby "${PROJECT_ROOT}/scripts/extract-provider-install-contract.rb" opencode)
OPENCODE_PACKAGE=$(echo "${OPENCODE_CONTRACT}" | sed -n 's/^PACKAGE=//p')
if [ -z "${OPENCODE_PACKAGE}" ]; then
    echo "ERROR: Could not extract OpenCode package from agent-harness" >&2
    exit 1
fi

# Extract Kilocode CLI install command from agent-harness (single source of truth).
KILOCODE_CONTRACT=$(bundle exec ruby "${PROJECT_ROOT}/scripts/extract-provider-install-contract.rb" kilocode)
KILOCODE_INSTALL_COMMAND=$(echo "${KILOCODE_CONTRACT}" | sed -n 's/^INSTALL_COMMAND=//p')

if [ -z "${KILOCODE_INSTALL_COMMAND}" ]; then
    echo "ERROR: Could not extract Kilocode CLI install command from agent-harness" >&2
    exit 1
fi

# Extract Gemini CLI install command from agent-harness (single source of truth).
GEMINI_CONTRACT=$(bundle exec ruby "${PROJECT_ROOT}/scripts/extract-provider-install-contract.rb" gemini)
GEMINI_CLI_INSTALL_COMMAND=$(echo "${GEMINI_CONTRACT}" | sed -n 's/^INSTALL_COMMAND=//p')

if [ -z "${GEMINI_CLI_INSTALL_COMMAND}" ]; then
    echo "ERROR: Could not extract Gemini CLI install command from agent-harness" >&2
    exit 1
fi

# Extract Aider CLI install command from agent-harness (single source of truth).
# agent-harness owns the uv bootstrap, aider-chat version pin, and install recipe.
AIDER_CONTRACT=$(bundle exec ruby "${PROJECT_ROOT}/scripts/extract-provider-install-contract.rb" aider)
AIDER_INSTALL_COMMAND=$(echo "${AIDER_CONTRACT}" | sed -n 's/^INSTALL_COMMAND=//p')

if [ -z "${AIDER_INSTALL_COMMAND}" ]; then
    echo "ERROR: Could not extract Aider CLI install command from agent-harness" >&2
    exit 1
fi

echo "Building agent container image..."
echo "  Image: ${FULL_IMAGE}"
echo "  Context: ${PROJECT_ROOT}/docker/agent"
echo "  ruby-maat: ${RUBY_MAAT_VERSION}"
echo "  claude-install: via agent-harness contract"
echo "  cursor-install: via agent-harness contract"
echo "  codex: ${CODEX_PACKAGE}"
echo "  opencode: ${OPENCODE_PACKAGE}"
echo "  kilocode-cli: ${KILOCODE_INSTALL_COMMAND}"
echo "  gemini-cli: ${GEMINI_CLI_INSTALL_COMMAND}"
echo "  aider-cli: via agent-harness contract"

"${DOCKER_BUILD_ENV[@]}" docker build \
    -t "${FULL_IMAGE}" \
    -f "${PROJECT_ROOT}/docker/agent/Dockerfile" \
    --build-arg "RUBY_MAAT_VERSION=${RUBY_MAAT_VERSION}" \
    --build-arg "CLAUDE_INSTALL_COMMAND=${CLAUDE_INSTALL_COMMAND}" \
    --build-arg "CLAUDE_POST_INSTALL_BINARY_PATH=${CLAUDE_POST_INSTALL_BINARY_PATH}" \
    --build-arg "CURSOR_ARTIFACT_URL=${CURSOR_ARTIFACT_URL}" \
    --build-arg "CURSOR_ARTIFACT_SHA256=${CURSOR_ARTIFACT_SHA256}" \
    --build-arg "CURSOR_BINARY_NAME=${CURSOR_BINARY_NAME}" \
    --build-arg "CURSOR_GLOBAL_PATH=${CURSOR_GLOBAL_PATH}" \
    --build-arg "CODEX_PACKAGE=${CODEX_PACKAGE}" \
    --build-arg "OPENCODE_PACKAGE=${OPENCODE_PACKAGE}" \
    --build-arg "KILOCODE_INSTALL_COMMAND=${KILOCODE_INSTALL_COMMAND}" \
    --build-arg "GEMINI_CLI_INSTALL_COMMAND=${GEMINI_CLI_INSTALL_COMMAND}" \
    --build-arg "AIDER_INSTALL_COMMAND=${AIDER_INSTALL_COMMAND}" \
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
