#!/usr/bin/env bash
# Executes the launch command documented in .paid/journeys.md inside the image
# that runs Paid-managed agents. Keeping the command in the guide as the
# source of truth catches toolchain and boot-time dependency drift.
# @spec LIVE-PREVIEW-012

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_NAME="${IMAGE_NAME:-paid-agent}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

if ! docker image inspect "${FULL_IMAGE}" > /dev/null 2>&1; then
  echo "Error: Image '${FULL_IMAGE}' not found. Build it first with:" >&2
  echo "  ./scripts/build-agent-image.sh" >&2
  exit 1
fi

docker run --rm \
  -v "${PROJECT_ROOT}:/workspace:ro" \
  -w /workspace \
  "${FULL_IMAGE}" \
  bash -lc '
    set -euo pipefail

    workspace=$(mktemp -d)
    trap "rm -rf \"${workspace}\"" EXIT
    cp -a /workspace/. "${workspace}"
    cd "${workspace}"

    BUNDLE_PATH="${workspace}/vendor/bundle" bundle install
    mkdir -p tmp

    launch_command=$(sed -n "s/^(\\(bundle exec bin\/rails server -b 0.0.0.0 -p 3000\\)) >.*/\\1/p" .paid/journeys.md)
    if [ -z "${launch_command}" ]; then
      echo "Could not find the documented Paid journey launch command" >&2
      exit 1
    fi

    bash -lc "${launch_command}" > tmp/paid-journey-launch-contract.log 2>&1 &
    server_pid=$!
    trap "kill \"${server_pid}\" 2>/dev/null || true; wait \"${server_pid}\" 2>/dev/null || true; rm -rf \"${workspace}\"" EXIT

    for _ in $(seq 1 30); do
      if curl --fail --silent --show-error http://127.0.0.1:3000/up > /dev/null; then
        exit 0
      fi
      if ! kill -0 "${server_pid}" 2>/dev/null; then
        cat tmp/paid-journey-launch-contract.log >&2
        exit 1
      fi
      sleep 1
    done

    cat tmp/paid-journey-launch-contract.log >&2
    exit 1
  '
