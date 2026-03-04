#!/bin/bash
# Configure LLM CLI tools to run in auto-approve/dangerous mode inside devcontainer
# This script runs during postCreateCommand to set up container-specific shell aliases
# and wrapper functions that enable dangerous mode without affecting host configs

set -euo pipefail

echo "Configuring LLM CLI tools for devcontainer..."

# Create wrapper directory for container-specific scripts
WRAPPER_DIR="/usr/local/bin/devcontainer-llm-wrappers"
sudo mkdir -p "$WRAPPER_DIR"

PLUGIN_DIR="/workspaces/claude-ai-toolkit"

# ============================================================================
# Claude Code
# ============================================================================

# Persist Claude state (~/.claude.json) across container rebuilds by
# symlinking it into the bind-mounted ~/.claude/ directory.
# This MUST happen before the VS Code extension launches Claude.
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

# Create Claude wrapper that adds --dangerously-skip-permissions and --plugin-dir
echo "Creating Claude wrapper..."
CLAUDE_BIN="$HOME/.local/bin/claude"
if [ -f "$CLAUDE_BIN" ] && [ ! -f "$CLAUDE_BIN.real" ]; then
  mv "$CLAUDE_BIN" "$CLAUDE_BIN.real"
  if [ -d "$PLUGIN_DIR" ]; then
    cat << CLAUDE_EOF > "$CLAUDE_BIN"
#!/bin/bash
# Claude wrapper for devcontainer - dangerous mode + plugin
exec "$CLAUDE_BIN.real" --dangerously-skip-permissions --plugin-dir "$PLUGIN_DIR" "\$@"
CLAUDE_EOF
  else
    echo "WARNING: Plugin directory $PLUGIN_DIR not found; skipping --plugin-dir flag." >&2
    cat << CLAUDE_EOF > "$CLAUDE_BIN"
#!/bin/bash
# Claude wrapper for devcontainer - dangerous mode
exec "$CLAUDE_BIN.real" --dangerously-skip-permissions "\$@"
CLAUDE_EOF
  fi
  chmod +x "$CLAUDE_BIN"
fi

# ============================================================================
# Codex (OpenAI)
# ============================================================================

# Create Codex wrapper that uses CLI flags for dangerous mode
echo "Creating Codex wrapper..."
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

# Create Aider wrapper that runs in non-interactive mode
echo "Creating Aider wrapper..."
cat << 'EOF' | sudo tee "$WRAPPER_DIR/aider" > /dev/null
#!/bin/bash
# Aider wrapper for devcontainer - non-interactive mode
# Check common installation locations
if [ -f "$HOME/.local/bin/aider" ]; then
  exec "$HOME/.local/bin/aider" "$@"
elif [ -f "/usr/local/bin/aider" ]; then
  exec /usr/local/bin/aider "$@"
else
  exec aider "$@"
fi
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
echo "Configuring Gemini CLI..."
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
# OpenCode, Kilocode, GitHub Copilot CLI, Cursor
# ============================================================================

# These tools use environment variables or their own config mechanisms
# OpenCode: Uses OPENCODE_PERMISSION environment variable (set in containerEnv if needed)
# Kilocode: Uses ~/.kilocode config (bind-mounted from host)
# GitHub Copilot CLI: Uses ~/.copilot config (bind-mounted from host)
# Cursor: Uses ~/.cursor config (bind-mounted from host)

echo ""
echo "LLM CLI tools configured for devcontainer!"
echo ""
echo "Configured tools:"
echo "  - Claude: Dangerous mode (--dangerously-skip-permissions)"
if [ -d "$PLUGIN_DIR" ]; then
  echo "            Plugin: claude-ai-toolkit loaded from $PLUGIN_DIR"
fi
echo "  - Codex: Auto-approve mode (approval_policy=never, sandbox=danger-full-access)"
echo "  - Gemini CLI: Auto-accept mode (autoAccept=true)"
echo "  - Aider: Non-interactive mode (auto-approval)"
echo "  - Cursor: Config mounted from host (~/.cursor)"
echo "  - OpenCode: Config mounted from host (~/.config)"
echo "  - Kilocode: Config mounted from host (~/.kilocode)"
echo "  - GitHub Copilot CLI: Config mounted from host (~/.copilot)"
echo ""
echo "WARNING: These tools will auto-approve all operations inside this container."
echo "  Host configurations remain unchanged and safe."
