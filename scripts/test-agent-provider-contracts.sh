#!/bin/bash
# Provider-contract smoke test for the paid-agent image.
# Validates that Paid's runnable-provider contract and generated config shape
# are compatible with the CLIs installed in the agent image.
#
# Usage:
#   ./scripts/test-agent-provider-contracts.sh
#   IMAGE_NAME=myregistry/paid-agent ./scripts/test-agent-provider-contracts.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INNER_SCRIPT="${SCRIPT_DIR}/test-agent-provider-contracts-inner.sh"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

IMAGE_NAME="${IMAGE_NAME:-paid-agent}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

echo "Provider-contract smoke test: ${FULL_IMAGE}"
echo "============================================="
echo ""

# Verify image exists
if ! docker image inspect "${FULL_IMAGE}" > /dev/null 2>&1; then
    echo "Error: Image '${FULL_IMAGE}' not found. Build it first with:"
    echo "  ./scripts/build-agent-image.sh"
    exit 1
fi

if [ ! -f "${INNER_SCRIPT}" ]; then
    echo "Error: inner test script not found: ${INNER_SCRIPT}"
    exit 1
fi

# Extract runtime contract values from app code without booting the full Rails
# environment or requiring a database connection.
CONTAINER_EXECUTABLE_KEYS=$(cd "${PROJECT_ROOT}" && bundle exec ruby -e "
  require 'bundler/setup'
  require 'agent_harness'
  \$LOAD_PATH.unshift('lib')
  require 'provider_support'
  puts ProviderSupport.container_executable_provider_keys.sort.join(' ')
")

# Generate the Codex config TOML body and notify line as Paid would.
CODEX_CONFIG_TOML_BODY=$(cd "${PROJECT_ROOT}" && bundle exec ruby -e "
  require 'bundler/setup'
  require 'agent_harness'
  provider = AgentHarness.provider(:codex)
  puts provider.config_file_content(
    model_provider: 'test',
    base_url: 'http://localhost:8080/api/proxy/openai',
    env_key: 'OPENAI_API_KEY',
    wire_api: 'responses'
  )
")

CODEX_NOTIFY_LINE=$(cd "${PROJECT_ROOT}" && bundle exec ruby -e "
  require 'bundler/setup'
  require_relative 'app/services/containers/provision'
  puts Containers::Provision.codex_notify_line
")

echo "Container-executable keys: ${CONTAINER_EXECUTABLE_KEYS}"
echo "Codex notify line: ${CODEX_NOTIFY_LINE}"
echo ""

docker run --rm \
    -v "${INNER_SCRIPT}:/tmp/contract-test.sh:ro" \
    -e "CONTAINER_EXECUTABLE_KEYS=${CONTAINER_EXECUTABLE_KEYS}" \
    -e "CODEX_NOTIFY_LINE=${CODEX_NOTIFY_LINE}" \
    -e "CODEX_CONFIG_TOML_BODY=${CODEX_CONFIG_TOML_BODY}" \
    "${FULL_IMAGE}" bash /tmp/contract-test.sh

echo ""
echo "============================================="
echo "Provider-contract smoke test completed successfully!"
