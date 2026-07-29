#!/bin/bash
# Initializes rtk (shell-output compression) and CodeGraph (code knowledge graph)
# for all installed AI agent CLIs in the devcontainer.
#
# Non-fatal: failures are logged but do not block container creation.
set -euo pipefail

echo "=== Setting up rtk (Rust Token Killer) ==="

# rtk init for each supported agent. Each call configures that agent's hook
# mechanism independently. --hook-only avoids adding RTK.md to context.
# Codex has no shell hook (AGENTS.md only), so rtk rejects --hook-only and
# --auto-patch for it — it gets a bare `rtk init -g --codex`.
rtk_init_for_selector() {
  local selector="$1"
  if [ "$selector" = "--codex" ]; then
    rtk init -g --codex
  else
    # shellcheck disable=SC2086
    rtk init -g --auto-patch --hook-only $selector
  fi
}

for selector in "" "--codex" "--gemini" "--opencode"; do
  if rtk_init_for_selector "$selector" 2>/dev/null; then
    echo "  rtk initialized for: ${selector:-claude/copilot (default)}"
  else
    echo "  WARNING: rtk init failed for: ${selector:-default} (non-fatal)"
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
