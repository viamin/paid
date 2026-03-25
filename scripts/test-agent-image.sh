#!/bin/bash
# Test script for verifying the agent container image
#
# Usage:
#   ./scripts/test-agent-image.sh              # Test default image
#   IMAGE_NAME=myregistry/paid-agent ./scripts/test-agent-image.sh  # Test custom image

set -e

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

# Run tests inside the container
docker run --rm "${FULL_IMAGE}" bash -c '
set -e
echo "Testing installed tools..."
echo ""

echo "1. Git:"
git --version

echo ""
echo "2. Node.js:"
node --version

echo ""
echo "3. npm:"
npm --version

echo ""
echo "4. Ruby:"
ruby --version

echo ""
echo "5. Bundler:"
bundler --version

echo ""
echo "6. Python:"
python3 --version

echo ""
check_command() {
    local label="$1"
    local command_name="$2"
    local version_args="${3:---version}"

    echo "${label}:"
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        echo "   ERROR: ${command_name} is not installed"
        exit 1
    fi

    # Some CLIs may require auth or print version details on stderr.
    "${command_name}" ${version_args} 2>&1 | head -n 1 || true
}

echo "7. Agent CLIs:"
check_command "   Claude Code CLI" claude
check_command "   OpenAI Codex CLI" codex
check_command "   Gemini CLI" gemini
check_command "   Kilocode CLI" kilo

echo ""
echo "8. Developer tools:"
check_command "   ast-grep" ast-grep
check_command "   scc" scc

echo ""
echo "9. User check (should be agent, not root):"
CURRENT_USER=$(whoami)
CURRENT_UID=$(id -u)
echo "   Current user: $CURRENT_USER (UID: $CURRENT_UID)"

if [ "$CURRENT_UID" -eq 0 ]; then
    echo "   ERROR: Running as root (UID 0), should be non-root user"
    exit 1
fi

if [ "$CURRENT_USER" != "agent" ]; then
    echo "   ERROR: Running as ${CURRENT_USER}, expected agent"
    exit 1
fi

echo "   ✓ Running as non-root user: agent"

echo ""
echo "10. Workspace directory:"
ls -la /workspace
if [ -w /workspace ]; then
    echo "   /workspace is writable"
else
    echo "   ERROR: /workspace is not writable"
    exit 1
fi

echo ""
echo "All tests passed!"
'

echo ""
echo "============================================="
echo "Image test completed successfully!"
