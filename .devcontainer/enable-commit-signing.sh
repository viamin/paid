#!/bin/bash
# Enable Git SSH commit signing inside the devcontainer.
set -euo pipefail

if ! command -v gh >/dev/null 2>&1; then
  echo "Error: GitHub CLI (gh) is not installed in this environment." >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "Error: git is not installed in this environment." >&2
  exit 1
fi

if ! gh auth status -h github.com >/dev/null 2>&1; then
  echo "GitHub CLI is not authenticated for github.com. Starting login..."
  gh auth login -h github.com
fi

echo "Ensuring token has admin:ssh_signing_key scope..."
gh auth refresh -h github.com -s admin:ssh_signing_key

echo "Configuring SSH commit signing for this repository..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "${SCRIPT_DIR}/setup-signing-key.sh"

echo

# Validate that signing was actually configured (setup-signing-key.sh may
# exit 0 without configuring anything if auth/scopes are missing).
if [[ "$(git config --local --get commit.gpgsign 2>/dev/null)" == "true" ]] \
  && [[ "$(git config --local --get gpg.format 2>/dev/null)" == "ssh" ]] \
  && [[ -n "$(git config --local --get user.signingkey 2>/dev/null)" ]]; then
  echo "Commit signing is enabled for this repo. Current git settings:"
  echo "  gpg.format      = $(git config --local --get gpg.format)"
  echo "  user.signingkey  = $(git config --local --get user.signingkey)"
  echo "  commit.gpgsign   = $(git config --local --get commit.gpgsign)"
else
  echo "ERROR: Commit signing was not configured." >&2
  echo "  The signing key setup did not complete successfully." >&2
  echo "  Check the output above for warnings and follow the suggested steps." >&2
  exit 1
fi
