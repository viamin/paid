#!/bin/bash
# Configure Claude Code to run in dangerous mode inside devcontainer
# This script runs during postCreateCommand to set up a container-specific
# wrapper that enables --dangerously-skip-permissions without affecting host configs

set -e

echo "Configuring Claude Code for devcontainer..."

PLUGIN_DIR="/workspaces/claude-ai-toolkit"

# Discover the Claude binary location
CLAUDE_BIN=$(which claude 2>/dev/null || echo "$HOME/.local/bin/claude")

if [ ! -f "$CLAUDE_BIN" ]; then
  echo "WARNING: Claude binary not found at $CLAUDE_BIN; devcontainer wrapper not configured." >&2
  exit 1
fi

if [ -f "$CLAUDE_BIN.real" ]; then
  echo "Claude devcontainer wrapper already configured; skipping wrapper creation." >&2
  exit 0
fi

# Build wrapper arguments
WRAPPER_ARGS="--dangerously-skip-permissions"

if [ -d "$PLUGIN_DIR" ]; then
  WRAPPER_ARGS="$WRAPPER_ARGS --plugin-dir $PLUGIN_DIR"
else
  echo "WARNING: Plugin directory $PLUGIN_DIR not found; skipping --plugin-dir flag." >&2
fi

# Create Claude wrapper that adds devcontainer-specific flags
mv "$CLAUDE_BIN" "$CLAUDE_BIN.real"
cat << WRAPPER > "$CLAUDE_BIN"
#!/bin/bash
# Claude wrapper for devcontainer - dangerous mode + plugin
exec "$CLAUDE_BIN.real" $WRAPPER_ARGS "\$@"
WRAPPER
chmod +x "$CLAUDE_BIN"

echo ""
echo "Claude Code configured for devcontainer!"
echo ""
echo "  - Claude: Dangerous mode (--dangerously-skip-permissions)"
if [ -d "$PLUGIN_DIR" ]; then
  echo "  - Plugin: claude-ai-toolkit loaded from $PLUGIN_DIR"
fi
echo ""
echo "WARNING: Claude will auto-approve all operations inside this container."
echo "  Host configurations remain unchanged and safe."
