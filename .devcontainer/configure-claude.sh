#!/bin/bash
# Configure Claude Code to run in dangerous mode inside devcontainer
# This script runs during postCreateCommand to set up a container-specific
# wrapper that enables --dangerously-skip-permissions without affecting host configs

set -e

echo "Configuring Claude Code for devcontainer..."

CLAUDE_BIN="$HOME/.local/bin/claude"

# Create Claude wrapper that adds --dangerously-skip-permissions and --plugin-dir
if [ -f "$CLAUDE_BIN" ] && [ ! -f "$CLAUDE_BIN.real" ]; then
  mv "$CLAUDE_BIN" "$CLAUDE_BIN.real"
  cat << EOF > "$CLAUDE_BIN"
#!/bin/bash
# Claude wrapper for devcontainer - dangerous mode + plugin
exec "$CLAUDE_BIN.real" --dangerously-skip-permissions --plugin-dir /workspaces/claude-ai-toolkit "\$@"
EOF
  chmod +x "$CLAUDE_BIN"
fi

echo ""
echo "Claude Code configured for devcontainer!"
echo ""
echo "  - Claude: Dangerous mode (--dangerously-skip-permissions)"
echo "  - Plugin: claude-ai-toolkit loaded from /workspaces/claude-ai-toolkit"
echo ""
echo "WARNING: Claude will auto-approve all operations inside this container."
echo "  Host configurations remain unchanged and safe."
