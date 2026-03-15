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

if ! gh auth status >/dev/null 2>&1; then
  echo "GitHub CLI is not authenticated. Starting login..."
  gh auth login -h github.com
fi

echo "Ensuring token has admin:ssh_signing_key scope..."
gh auth refresh -h github.com -s admin:ssh_signing_key

echo "Configuring SSH commit signing for this repository..."
bash "$(dirname "$0")/setup-signing-key.sh"

echo

echo "Commit signing is enabled for this repo. Current git settings:"
git config --local --get gpg.format || true
git config --local --get user.signingkey || true
git config --local --get commit.gpgsign || true
