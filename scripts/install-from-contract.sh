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
LOCAL_BIN_DIR="${HOME}/.local/bin"
LOCAL_SHARE_DIR="${HOME}/.local/share"
export PATH="${LOCAL_BIN_DIR}:${PATH}"

ensure_user_local_dirs() {
  mkdir -p "$LOCAL_BIN_DIR" "$LOCAL_SHARE_DIR"
}

path_is_writable_or_creatable() {
  local path="$1"
  local parent_dir

  if [ -e "$path" ]; then
    [ -w "$path" ]
    return
  fi

  parent_dir="$(dirname "$path")"
  [ -d "$parent_dir" ] && [ -w "$parent_dir" ]
}

prefer_user_local_path() {
  local path="$1"
  local fallback_path

  case "$path" in
    /usr/local/bin/*)
      fallback_path="${LOCAL_BIN_DIR}/$(basename "$path")"
      ;;
    /opt/uv/tools)
      fallback_path="${LOCAL_SHARE_DIR}/uv/tools"
      ;;
    /opt/uv/python)
      fallback_path="${LOCAL_SHARE_DIR}/uv/python"
      ;;
    /opt/cursor-agent)
      fallback_path="${LOCAL_SHARE_DIR}/cursor-agent"
      ;;
    *)
      printf '%s\n' "$path"
      return
  esac

  if path_is_writable_or_creatable "$path"; then
    printf '%s\n' "$path"
    return
  fi

  ensure_user_local_dirs
  printf '%s\n' "$fallback_path"
}

rewrite_install_command_for_user_paths() {
  local command="$1"

  if [ ! -w /usr/local/bin ]; then
    command="${command//\/usr\/local\/bin/${LOCAL_BIN_DIR}}"
  fi

  if [ ! -w /opt ]; then
    command="${command//\/opt\/uv\/tools/${LOCAL_SHARE_DIR}\/uv\/tools}"
    command="${command//\/opt\/uv\/python/${LOCAL_SHARE_DIR}\/uv\/python}"
  fi

  printf '%s\n' "$command"
}

rewrite_uv_command_if_needed() {
  local command="$1"

  if command -v uv > /dev/null 2>&1; then
    printf '%s\n' "$command"
    return
  fi

  if python3 -m uv --help > /dev/null 2>&1; then
    command="${command// uv tool install/ python3 -m uv tool install}"
  fi

  printf '%s\n' "$command"
}

rewrite_pip_command_if_needed() {
  local command="$1"

  if python3 -m pip --version > /dev/null 2>&1; then
    printf '%s\n' "$command"
    return
  fi

  if command -v pip3 > /dev/null 2>&1; then
    command="${command//python3 -m pip/pip3}"
  fi

  printf '%s\n' "$command"
}

ensure_pip_available() {
  if python3 -m pip --version > /dev/null 2>&1; then
    return
  fi

  if command -v pip3 > /dev/null 2>&1; then
    return
  fi

  if python3 -m ensurepip --upgrade > /dev/null 2>&1; then
    return
  fi

  echo "ERROR: Python pip is required for uv_tool providers." >&2
  echo "Rebuild the devcontainer image so python3-pip is installed, then rerun the postCreateCommand." >&2
  exit 1
}

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
  INSTALL_ROOT=$(prefer_user_local_path /opt/cursor-agent)
  GLOBAL_PATH=$(prefer_user_local_path "$GLOBAL_PATH")

  mkdir -p /tmp/cursor-install "$INSTALL_ROOT" "$(dirname "$GLOBAL_PATH")"
  curl -fsSL "$ARTIFACT_URL" -o /tmp/cursor-artifact.tar.gz
  echo "$ARTIFACT_SHA256  /tmp/cursor-artifact.tar.gz" | sha256sum -c -
  tar -xzf /tmp/cursor-artifact.tar.gz -C /tmp
  cp -R /tmp/dist-package/. "$INSTALL_ROOT/"
  test -f "$INSTALL_ROOT/$BINARY_NAME"
  chmod +x "$INSTALL_ROOT/$BINARY_NAME"
  ln -sf "$INSTALL_ROOT/$BINARY_NAME" "$GLOBAL_PATH"
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
    ensure_pip_available
    INSTALL_COMMAND=$(rewrite_install_command_for_user_paths "$INSTALL_COMMAND")
    INSTALL_COMMAND=$(rewrite_pip_command_if_needed "$INSTALL_COMMAND")
    INSTALL_COMMAND=$(rewrite_uv_command_if_needed "$INSTALL_COMMAND")
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
