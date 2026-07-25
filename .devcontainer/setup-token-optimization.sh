#!/bin/bash
# Initializes rtk (shell-output compression) and CodeGraph (code knowledge graph)
# for all installed AI agent CLIs in the devcontainer.
#
# Non-fatal: failures are logged but do not block container creation.
set -euo pipefail

echo "=== Setting up rtk (Rust Token Killer) ==="

# rtk init for each supported agent. Each call configures that agent's hook
# mechanism independently. --hook-only avoids adding RTK.md to context.
for flags in "" "--codex" "--gemini" "--opencode"; do
  if rtk init -g --auto-patch --hook-only $flags 2>/dev/null; then
    echo "  rtk initialized for: ${flags:-claude/copilot (default)}"
  else
    echo "  WARNING: rtk init failed for: ${flags:-default} (non-fatal)"
  fi
done

echo ""
echo "=== Setting up CodeGraph ==="

# Initialize the code knowledge graph for this workspace.
if codegraph init 2>/dev/null; then
  echo "  CodeGraph graph built for workspace"
else
  echo "  WARNING: codegraph init failed (non-fatal)"
fi

# Configure codegraph as a global MCP server for all detected agents.
# --location=global avoids modifying project files (CLAUDE.md/AGENTS.md).
if codegraph install --yes --location=global --no-permissions 2>/dev/null; then
  echo "  CodeGraph MCP configured for detected agents"
else
  echo "  WARNING: codegraph install failed (non-fatal)"
fi

echo ""
echo "Token optimization setup complete."
