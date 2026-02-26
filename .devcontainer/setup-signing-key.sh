#!/bin/bash
# Generate a container-local SSH signing key and register it with GitHub.
# Runs as a postCreateCommand — the key is ephemeral (regenerated on each
# container creation) so we clean up stale keys from previous containers.
set -euo pipefail

# Ensure we're in the workspace root (required for git config --local)
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo /workspaces/paid)"

KEY_DIR="$HOME/.ssh-signing"
KEY_PATH="$KEY_DIR/id_ed25519"
TITLE_PREFIX="devcontainer-signing:"
KEY_TITLE="$TITLE_PREFIX $(hostname)"

# 0. Verify GitHub CLI authentication and required scope
if ! gh auth status >/dev/null 2>&1; then
  echo "Error: GitHub CLI is not authenticated. Run 'gh auth login' first." >&2
  exit 1
fi

if ! gh api /user/ssh_signing_keys --method GET --paginate --jq '.' >/dev/null 2>&1; then
  echo "WARNING: GitHub token lacks the 'admin:ssh_signing_key' scope." >&2
  echo "  Commit signing will be disabled. To enable it, run:" >&2
  echo "    gh auth refresh -h github.com -s admin:ssh_signing_key" >&2
  echo "  Then re-run: bash .devcontainer/setup-signing-key.sh" >&2
  exit 0
fi

# 1. Generate key (overwrite any leftover from a previous build)
echo "Generating SSH signing key..."
mkdir -p "$KEY_DIR"
rm -f "$KEY_PATH" "$KEY_PATH.pub"
ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -q
chmod 700 "$KEY_DIR"
chmod 600 "$KEY_PATH"

# 2. Remove stale devcontainer signing keys from this container's hostname.
#    Only keys matching this hostname are removed so concurrent devcontainers
#    with different hostnames are unaffected.
echo "Cleaning up old signing keys from GitHub..."
if ! key_ids=$(gh api /user/ssh_signing_keys --paginate --jq \
  ".[] | select(.title == \"$KEY_TITLE\") | .id"); then
  echo "WARNING: Failed to list existing SSH keys from GitHub; skipping cleanup of old signing keys." >&2
else
  if [[ -n "$key_ids" ]]; then
    while read -r key_id; do
      if ! output=$(gh api "/user/ssh_signing_keys/$key_id" --method DELETE 2>&1); then
        if echo "$output" | grep -qi "not found"; then
          # Key is already absent; this is safe to ignore.
          :
        else
          echo "$output" >&2
          echo "WARNING: Failed to delete key $key_id" >&2
        fi
      fi
    done <<< "$key_ids"
  fi
fi

# 3. Register the new public key with GitHub
echo "Registering new signing key with GitHub..."
if ! gh ssh-key add "$KEY_PATH.pub" --type signing --title "$KEY_TITLE"; then
  echo "WARNING: Failed to register signing key with GitHub." >&2
  echo "  Commit signing will be disabled. To fix, run:" >&2
  echo "    gh auth refresh -h github.com -s admin:ssh_signing_key" >&2
  echo "  Then re-run: bash .devcontainer/setup-signing-key.sh" >&2
  exit 0
fi

# 4. Configure git to use the key for commit signing (repo-local to avoid
#    contaminating the host .gitconfig which is bind-mounted into the container)
git config --local gpg.format ssh
git config --local user.signingkey "$KEY_PATH"
git config --local commit.gpgsign true

echo "SSH signing configured successfully!"
