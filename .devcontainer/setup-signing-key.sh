#!/bin/bash
# Generate a container-local SSH signing key and register it with GitHub.
# Runs as a postCreateCommand — the key is ephemeral (regenerated on each
# container creation) so we clean up stale keys from previous containers.
set -euo pipefail

KEY_DIR="$HOME/.ssh-signing"
KEY_PATH="$KEY_DIR/id_ed25519"
TITLE_PREFIX="devcontainer-signing:"
KEY_TITLE="$TITLE_PREFIX $(hostname)"

# 0. Verify GitHub CLI authentication
if ! gh auth status >/dev/null 2>&1; then
  echo "Error: GitHub CLI is not authenticated. Run 'gh auth login' first." >&2
  exit 1
fi

# 1. Generate key (overwrite any leftover from a previous build)
echo "Generating SSH signing key..."
mkdir -p "$KEY_DIR"
rm -f "$KEY_PATH" "$KEY_PATH.pub"
ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -q
chmod 700 "$KEY_DIR"
chmod 600 "$KEY_PATH"

# 2. Remove stale devcontainer signing keys from GitHub
echo "Cleaning up old signing keys from GitHub..."
while read -r key_id; do
  gh ssh-key delete "$key_id" --yes 2>&1 | grep -v "not found" || echo "Warning: Failed to delete key $key_id" >&2
done < <(gh ssh-key list --json id,title \
  | jq -r ".[] | select(.title | startswith(\"$TITLE_PREFIX\")) | .id")

# 3. Register the new public key with GitHub
echo "Registering new signing key with GitHub..."
gh ssh-key add "$KEY_PATH.pub" --type signing --title "$KEY_TITLE"

# 4. Configure git to use the key for commit signing (repo-local to avoid
#    contaminating the host .gitconfig which is bind-mounted into the container)
git config --local gpg.format ssh
git config --local user.signingkey "$KEY_PATH"
git config --local commit.gpgsign true

echo "SSH signing configured successfully!"
