#!/usr/bin/env bash
# Journey launch-contract check for the paid-agent image.
#
# The Paid journey guide (.paid/journeys.md) documents the command that starts
# the application for interactive verification. That command has to run inside
# the image that executes Paid-managed agents, so this check resolves the
# documented command against the image and fails when the container cannot
# satisfy it. The guide stays the source of truth: the check reads the command
# from the guide instead of restating it here.
#
# @spec LIVE-PREVIEW-012

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# The inner check runs inside the image, where the checkout is mounted at
# /workspace.
CONTAINER_WORKSPACE="/workspace"
INNER_SCRIPT="scripts/test-paid-journey-launch-contract-inner.sh"

IMAGE_NAME="${IMAGE_NAME:-paid-agent}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

echo "Journey launch-contract check: ${FULL_IMAGE}"
echo "============================================="
echo ""

if ! docker image inspect "${FULL_IMAGE}" > /dev/null 2>&1; then
  echo "Error: Image '${FULL_IMAGE}' not found. Build it first with:" >&2
  echo "  ./scripts/build-agent-image.sh" >&2
  exit 1
fi

if [ ! -f "${PROJECT_ROOT}/${INNER_SCRIPT}" ]; then
  echo "Error: inner test script not found: ${PROJECT_ROOT}/${INNER_SCRIPT}" >&2
  exit 1
fi

# The checkout is mounted read-only so the inner check sees the same guide and
# repository scripts the agent would see, without letting the check modify the
# working tree.
docker run --rm \
    -v "${PROJECT_ROOT}:${CONTAINER_WORKSPACE}:ro" \
    -w "${CONTAINER_WORKSPACE}" \
    "${FULL_IMAGE}" \
    bash "${CONTAINER_WORKSPACE}/${INNER_SCRIPT}"

echo ""
echo "============================================="
echo "Journey launch contract satisfied."
