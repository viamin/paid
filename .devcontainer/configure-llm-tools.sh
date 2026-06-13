#!/bin/bash
# Configure LLM CLI tools to run in auto-approve/dangerous mode inside devcontainer.
# This script runs during postCreateCommand to set up container-specific wrappers
# and configuration. Agent CLI tool state lives in named Docker volumes (see
# compose.yaml), so config written here is container-local and persists across
# rebuilds without touching the host. Only git/ssh/GitHub-CLI config is still
# bind-mounted from the host.

set -euo pipefail
set -x
echo "[DEBUG] Starting configure-llm-tools.sh"

echo "Configuring LLM CLI tools for devcontainer..."


echo "[DEBUG] Creating wrapper directory..."
WRAPPER_DIR="/usr/local/bin/devcontainer-llm-wrappers"
sudo mkdir -p "$WRAPPER_DIR"


# ============================================================================
# Claude Code
# ============================================================================


echo "[DEBUG] Setting up Claude state symlink..."
CLAUDE_STATE="$HOME/.claude.json"
CLAUDE_STATE_PERSISTENT="$HOME/.claude/claude.json"

if [ -L "$CLAUDE_STATE" ]; then
  echo "Claude state symlink already exists; skipping."
elif [ -f "$CLAUDE_STATE" ] && [ -f "$CLAUDE_STATE_PERSISTENT" ]; then
  # Fresh file created in this session but we have persisted data — keep persisted
  rm "$CLAUDE_STATE"
  ln -s "$CLAUDE_STATE_PERSISTENT" "$CLAUDE_STATE"
  echo "Claude state restored from persistent mount (discarded fresh file)."
elif [ -f "$CLAUDE_STATE" ]; then
  # No persisted data yet — migrate the current file
  mv "$CLAUDE_STATE" "$CLAUDE_STATE_PERSISTENT"
  ln -s "$CLAUDE_STATE_PERSISTENT" "$CLAUDE_STATE"
  echo "Claude state migrated into persistent mount."
else
  # No file exists yet — create symlink so Claude writes directly to the mount
  ln -s "$CLAUDE_STATE_PERSISTENT" "$CLAUDE_STATE"
  echo "Claude state symlink created (will be populated on first launch)."
fi

# Resolve Claude binary location: prefer PATH, fall back to default install path

echo "[DEBUG] Resolving Claude binary..."
CLAUDE_BIN_DEFAULT="$HOME/.local/bin/claude"
CLAUDE_BIN_RESOLVED="$(command -v claude 2>/dev/null || true)"

if [ -n "$CLAUDE_BIN_RESOLVED" ]; then
  CLAUDE_BIN="$CLAUDE_BIN_RESOLVED"
elif [ -f "$CLAUDE_BIN_DEFAULT" ]; then
  CLAUDE_BIN="$CLAUDE_BIN_DEFAULT"
else
  echo "WARNING: Claude CLI binary not found in PATH or at $CLAUDE_BIN_DEFAULT; skipping wrapper." >&2
  CLAUDE_BIN=""
fi

# Create Claude wrapper that adds --dangerously-skip-permissions
if [ -n "$CLAUDE_BIN" ] && [ -f "$CLAUDE_BIN" ] && [ ! -f "$CLAUDE_BIN.real" ]; then
  echo "[DEBUG] Creating Claude wrapper..."
  mv "$CLAUDE_BIN" "$CLAUDE_BIN.real"
  cat << CLAUDE_EOF > "$CLAUDE_BIN"
#!/bin/bash
# Claude wrapper for devcontainer - dangerous mode
exec "$CLAUDE_BIN.real" --dangerously-skip-permissions "\$@"
CLAUDE_EOF
  chmod +x "$CLAUDE_BIN"
fi

# ============================================================================
# Codex (OpenAI)
# ============================================================================

# Create Codex wrapper that uses CLI flags for dangerous mode
echo "[DEBUG] Creating Codex wrapper..."
cat << 'EOF' | sudo tee "$WRAPPER_DIR/codex" > /dev/null
#!/bin/bash
# Codex wrapper for devcontainer - auto-approve mode
exec /usr/local/bin/codex.real -a never -s danger-full-access "$@"
EOF
sudo chmod +x "$WRAPPER_DIR/codex"

# Rename original codex if it exists in /usr/local/bin
if [ -f "/usr/local/bin/codex" ] && [ ! -f "/usr/local/bin/codex.real" ]; then
  sudo mv /usr/local/bin/codex /usr/local/bin/codex.real
  sudo ln -sf "$WRAPPER_DIR/codex" /usr/local/bin/codex
fi

# ============================================================================
# Aider
# ============================================================================

# Create Aider path shim (resolves install location; does not add auto-approval flags
# since Aider does not have a global auto-approve mode)
echo "[DEBUG] Creating Aider path shim..."
cat << 'EOF' | sudo tee "$WRAPPER_DIR/aider" > /dev/null
#!/bin/bash
# Aider path shim for devcontainer
# Prefer user-local installation if present
if [ -f "$HOME/.local/bin/aider" ]; then
  exec "$HOME/.local/bin/aider" "$@"
fi

# Resolve this shim's canonical path to avoid recursion
SELF_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
AIDER_CMD="$(command -v aider 2>/dev/null || true)"
if [ -n "$AIDER_CMD" ]; then
  AIDER_REAL="$(readlink -f "$AIDER_CMD" 2>/dev/null || echo "$AIDER_CMD")"
  if [ "$AIDER_REAL" != "$SELF_PATH" ]; then
    exec "$AIDER_CMD" "$@"
  fi
fi

echo "Error: could not locate a real 'aider' binary." >&2
exit 1
EOF
sudo chmod +x "$WRAPPER_DIR/aider"

# Link to /usr/local/bin if not already present
if [ ! -f "/usr/local/bin/aider" ]; then
  sudo ln -sf "$WRAPPER_DIR/aider" /usr/local/bin/aider
fi

# ============================================================================
# Gemini CLI
# ============================================================================

# For Gemini CLI, create a container-specific settings file
# We put it in /etc to avoid conflicts with bind-mounted ~/.config
echo "[DEBUG] Configuring Gemini CLI..."
sudo mkdir -p /etc/gemini-cli
cat << 'EOF' | sudo tee /etc/gemini-cli/settings.json > /dev/null
{
  "autoAccept": true
}
EOF
DEVCONTAINER_USER="${SUDO_USER:-${USER}}"
DEVCONTAINER_GROUP="$(id -gn "${DEVCONTAINER_USER}")"
sudo chown -R "${DEVCONTAINER_USER}:${DEVCONTAINER_GROUP}" /etc/gemini-cli
sudo chmod -R u+rwX,go+rX /etc/gemini-cli

# Create Gemini wrapper that uses the container-specific config
cat << 'EOF' | sudo tee "$WRAPPER_DIR/gemini" > /dev/null
#!/bin/bash
# Gemini wrapper for devcontainer - auto-accept mode
# Point to container-specific config that won't affect host
export GEMINI_CONFIG_DIR=/etc/gemini-cli
exec /usr/local/bin/gemini.real "$@"
EOF
sudo chmod +x "$WRAPPER_DIR/gemini"

if [ -f "/usr/local/bin/gemini" ] && [ ! -f "/usr/local/bin/gemini.real" ]; then
  sudo mv /usr/local/bin/gemini /usr/local/bin/gemini.real
  sudo ln -sf "$WRAPPER_DIR/gemini" /usr/local/bin/gemini
fi

# ============================================================================
# KiloCode
# ============================================================================

# KiloCode reads config from ~/.config/kilo/, which is on the container's
# writable layer (rebuilt each time); ~/.kilocode is a persisted named volume.
# Either way this config stays container-local.
echo "[DEBUG] Configuring KiloCode..."
mkdir -p "$HOME/.config/kilo"
# NOTE: the schema's string shortcut `"permission": "allow"` is semantically
# correct ("dangerously skip permissions") but triggers an upstream kilo bug
# where its save-merge (`{...config.permission, <key>: "allow"}`) spreads the
# string character-by-character into `{0:"a",1:"l",...}` and corrupts the
# file. We use the object form with every known key explicitly set to "allow"
# so the spread-merge is a no-op. Revert to the string shortcut once the
# upstream save bug is fixed. Keys from https://app.kilo.ai/config.json.
cat << 'EOF' > "$HOME/.config/kilo/config.json"
{
  "$schema": "https://app.kilo.ai/config.json",
  "permission": {
    "read": "allow",
    "edit": "allow",
    "glob": "allow",
    "grep": "allow",
    "list": "allow",
    "bash": "allow",
    "task": "allow",
    "external_directory": "allow",
    "todowrite": "allow",
    "question": "allow",
    "webfetch": "allow",
    "websearch": "allow",
    "codesearch": "allow",
    "lsp": "allow",
    "doom_loop": "allow",
    "skill": "allow"
  }
}
EOF

# ============================================================================
# OpenCode
# ============================================================================

# ~/.config/opencode is a persisted named volume (container-local), so writing
# opencode.json here won't affect any host OpenCode installation.
echo "[DEBUG] Configuring OpenCode..."
# Ensure ~/.config/opencode is owned by the devcontainer user and writable
mkdir -p "$HOME/.config/opencode"
sudo chown -R "${DEVCONTAINER_USER:-$USER}:${DEVCONTAINER_GROUP:-$(id -gn "${DEVCONTAINER_USER:-$USER}")}" "$HOME/.config/opencode"
sudo chmod -R u+rwX "$HOME/.config/opencode"
# Assert auto-approve mode without clobbering the rest of opencode.json. Because
# this dir is now a persisted volume, an unconditional overwrite would wipe both
# user customizations and the Compound Engineering plugin's config on every
# rebuild — so merge "permission": "allow" into any existing config (jq), and
# only write a fresh file when jq is unavailable or no valid config exists yet.
OPENCODE_CONFIG="$HOME/.config/opencode/opencode.json"
if command -v jq >/dev/null 2>&1 && [ -s "$OPENCODE_CONFIG" ] && jq -e . "$OPENCODE_CONFIG" >/dev/null 2>&1; then
  tmp_oc="$(mktemp)"
  if jq '. + {permission: "allow"}' "$OPENCODE_CONFIG" > "$tmp_oc"; then
    mv "$tmp_oc" "$OPENCODE_CONFIG"
  else
    rm -f "$tmp_oc"
    echo "WARNING: failed to merge opencode.json; leaving existing file unchanged." >&2
  fi
else
  cat << 'EOF' > "$OPENCODE_CONFIG"
{
  "$schema": "https://opencode.ai/config.json",
  "permission": "allow"
}
EOF
fi

# ============================================================================
# GitHub Copilot CLI, Cursor
# ============================================================================

# GitHub Copilot CLI: Uses ~/.copilot config (bind-mounted from host)
# Cursor: Uses ~/.cursor config (bind-mounted from host)

echo ""
echo "[DEBUG] LLM CLI tools configured for devcontainer!"
echo ""
echo "Configured tools:"
echo "  - Claude: Dangerous mode (--dangerously-skip-permissions)"
echo "  - Codex: Auto-approve mode (approval_policy=never, sandbox=danger-full-access)"
echo "  - Gemini CLI: Auto-accept mode (autoAccept=true)"
echo "  - KiloCode: Auto-approve mode (permission=allow, container-specific config)"
echo "  - Aider: Path shim (no global auto-approve mode available)"
echo "  - Cursor: Config mounted from host (~/.cursor)"
echo "  - OpenCode: Auto-approve mode (permission=allow, container-specific config)"
echo "  - GitHub Copilot CLI: Config mounted from host (~/.copilot)"
echo ""
echo "WARNING: These tools will auto-approve all operations inside this container."
echo "  Agent tool state is kept in container-local named volumes (not the host)."
echo "  Use only in isolated/dev environments where this behavior is acceptable."
