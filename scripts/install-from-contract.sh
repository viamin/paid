#!/bin/bash

# Install a provider tool from its agent-harness contract.
#
# This is the single source of truth for devcontainer AI tool installation.
# It wraps `scripts/extract-provider-install-contract.rb`, consuming the
# contract output to drive install commands that are identical to the ones
# the agent image uses in production.
#
# Usage:
#   scripts/install-from-contract.sh <provider>
#
# Supported providers: codex, gemini, copilot, kilocode, cursor, aider, opencode

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Wait for bundle install to complete before calling bundle exec.
# In devcontainer postCreateCommand, entries run in parallel, so bin/setup
# (which runs bundle install) may not have finished yet.
max_wait=300
waited=0
while ! bundle check > /dev/null 2>&1; do
  if [ "$waited" -ge "$max_wait" ]; then
    echo "ERROR: Timed out waiting for bundle install (${max_wait}s)" >&2
    exit 1
  fi
  sleep 5
  waited=$((waited + 5))
done

PROVIDER="${1:-}"
if [ -z "$PROVIDER" ]; then
  echo "Usage: $0 <provider>" >&2
  echo "Supported providers: codex, gemini, copilot, kilocode, cursor, aider, opencode" >&2
  exit 1
fi

CONTRACT=$(bundle exec ruby "${PROJECT_ROOT}/scripts/extract-provider-install-contract.rb" "$PROVIDER") || {
  echo "ERROR: Failed to fetch contract for provider: $PROVIDER" >&2
  exit 1
}

# Check for artifact-based install first (Cursor uses this mechanism).
# The script outputs ARTIFACT_URL when the provider uses artifact-based install.
ARTIFACT_URL=$(echo "$CONTRACT" | sed -n 's/^ARTIFACT_URL=//p')

if [ -n "$ARTIFACT_URL" ]; then
  # Cursor: artifact-based install with SHA256 verification.
  # Extract the pinned URL and SHA256 from the contract and install
  # directly, mirroring the agent Dockerfile's approach.
  ARTIFACT_SHA256=$(echo "$CONTRACT" | sed -n 's/^ARTIFACT_SHA256=//p')
  BINARY_NAME=$(echo "$CONTRACT" | sed -n 's/^BINARY_NAME=//p')
  GLOBAL_PATH=$(echo "$CONTRACT" | sed -n 's/^GLOBAL_PATH=//p')

  if [ -z "$ARTIFACT_SHA256" ]; then
    echo "ERROR: Missing cursor artifact SHA256 in contract" >&2
    exit 1
  fi

  echo "Installing $PROVIDER via artifact (SHA256 verified)"
  mkdir -p /tmp/cursor-install /opt/cursor-agent "$(dirname "$GLOBAL_PATH")"
  curl -fsSL "$ARTIFACT_URL" -o /tmp/cursor-artifact.tar.gz
  echo "$ARTIFACT_SHA256  /tmp/cursor-artifact.tar.gz" | sha256sum -c -
  tar -xzf /tmp/cursor-artifact.tar.gz -C /tmp
  cp -R /tmp/dist-package/. /opt/cursor-agent/
  test -f "/opt/cursor-agent/$BINARY_NAME"
  chmod +x "/opt/cursor-agent/$BINARY_NAME"
  ln -sf "/opt/cursor-agent/$BINARY_NAME" "$GLOBAL_PATH"
  rm -rf /tmp/cursor-artifact.tar.gz /tmp/dist-package
  echo "$PROVIDER installed at $GLOBAL_PATH"
else
  SOURCE=$(echo "$CONTRACT" | sed -n 's/^SOURCE=//p')

  case "$SOURCE" in
  npm)
    INSTALL_COMMAND=$(echo "$CONTRACT" | sed -n 's/^INSTALL_COMMAND=//p')
    if [ -z "$INSTALL_COMMAND" ]; then
      echo "ERROR: No INSTALL_COMMAND in contract for provider: $PROVIDER" >&2
      exit 1
    fi
    case "$INSTALL_COMMAND" in
      *--ignore-scripts*) ;;
      *)
        echo "ERROR: INSTALL_COMMAND for npm provider $PROVIDER must include --ignore-scripts" >&2
        exit 1
        ;;
    esac
    echo "Installing $PROVIDER via npm contract"
    eval "$INSTALL_COMMAND"
    ;;

  uv_tool)
    INSTALL_COMMAND=$(echo "$CONTRACT" | sed -n 's/^INSTALL_COMMAND=//p')
    if [ -z "$INSTALL_COMMAND" ]; then
      echo "ERROR: No INSTALL_COMMAND in contract for provider: $PROVIDER" >&2
      exit 1
    fi
    echo "Installing $PROVIDER via uv_tool"
    eval "$INSTALL_COMMAND"
    ;;

  *)
    # Shell-based provider (e.g., copilot which provides a full install command)
    INSTALL_COMMAND=$(echo "$CONTRACT" | sed -n 's/^INSTALL_COMMAND=//p')
    if [ -z "$INSTALL_COMMAND" ]; then
      echo "ERROR: No INSTALL_COMMAND in contract for provider: $PROVIDER" >&2
      exit 1
    fi
    echo "Installing $PROVIDER via shell contract"
    eval "$INSTALL_COMMAND"
    ;;
  esac
fi
