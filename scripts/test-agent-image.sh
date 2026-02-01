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
echo "7. Claude Code CLI:"
if npm list -g @anthropic/claude-code >/dev/null 2>&1; then
    echo "   @anthropic/claude-code is installed globally"
    if command -v claude >/dev/null 2>&1; then
        claude --version 2>/dev/null || echo "   (claude command exists, may require API key to show version)"
    else
        echo "   WARNING: @anthropic/claude-code installed but claude command not in PATH"
    fi
else
    echo "   ERROR: @anthropic/claude-code is not installed"
    exit 1
fi

echo ""
echo "8. User check (should be agent, not root):"
CURRENT_USER=$(whoami)
CURRENT_UID=$(id -u)
echo "   Current user: $CURRENT_USER (UID: $CURRENT_UID)"

if [ "$CURRENT_UID" -eq 0 ]; then
    echo "   ERROR: Running as root (UID 0), should be non-root user"
    exit 1
fi

if [ "$CURRENT_USER" != "agent" ]; then
    echo "   ERROR: Running as '$CURRENT_USER', expected 'agent'"
    exit 1
fi

echo "   ✓ Running as non-root user 'agent'"

echo ""
echo "9. Workspace directory:"
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
