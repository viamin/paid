#!/bin/bash
# Generate a container-local SSH signing key and register it with GitHub.
# Runs as a postCreateCommand — the key is ephemeral (regenerated on each
# container creation) so we clean up stale keys from previous containers.
set -euo pipefail

KEY_DIR="$HOME/.ssh-signing"
KEY_PATH="$KEY_DIR/id_ed25519"
TITLE_PREFIX="devcontainer-signing:"
KEY_TITLE="$TITLE_PREFIX $(hostname)"

# 1. Generate key (overwrite any leftover from a previous build)
mkdir -p "$KEY_DIR"
ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -q <<< y

# 2. Remove stale devcontainer signing keys from GitHub
gh ssh-key list --json id,title \
  | jq -r ".[] | select(.title | startswith(\"$TITLE_PREFIX\")) | .id" \
  | while read -r key_id; do
      gh ssh-key delete "$key_id" --yes 2>/dev/null || true
    done

# 3. Register the new public key with GitHub
gh ssh-key add "$KEY_PATH.pub" --type signing --title "$KEY_TITLE"

# 4. Configure git to use the key for commit signing
git config --global gpg.format ssh
git config --global user.signingkey "$KEY_PATH.pub"
git config --global commit.gpgsign true
