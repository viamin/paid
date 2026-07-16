#!/bin/bash
# Ensure the agent CLI tool directories backed by named Docker volumes are owned
# by the devcontainer user.
#
# Docker initializes a brand-new (empty) named volume owned by root:root, so the
# first time these volumes are created their mount points are not writable by
# `vscode`. This runs as onCreateCommand (before postCreate), so configure-llm-
# tools.sh, bin/setup, and the plugin install can all write into them. On later
# rebuilds the volumes persist and are already vscode-owned, making this a no-op.
#
# Non-fatal by design: a permission problem on one secondary tool's volume warns
# and continues rather than aborting the whole devcontainer build. Downstream
# steps that truly need a writable dir (e.g. configure-llm-tools.sh) re-chown or
# fail on their own with a clearer error.

set -uo pipefail

AGENT_DIRS=(
  "$HOME/.claude"
  "$HOME/.codex"
  "$HOME/.config/opencode"
  "$HOME/.local/share/opencode"
  "$HOME/.copilot"
  "$HOME/.kilocode"
  "$HOME/.aider"
  "$HOME/.cursor"
  "$HOME/.omp"
)

for dir in "${AGENT_DIRS[@]}"; do
  mkdir -p "$dir" || { echo "init-agent-volumes: WARNING could not create $dir" >&2; continue; }
  # Only chown when the mount point is not already owned by us, to avoid a slow
  # recursive chown over large persisted volumes on every rebuild.
  if [ "$(stat -c '%U' "$dir")" != "$(id -un)" ]; then
    if sudo chown -R "$(id -un):$(id -gn)" "$dir"; then
      echo "init-agent-volumes: claimed $dir"
    else
      echo "init-agent-volumes: WARNING could not chown $dir" >&2
    fi
  fi
done

echo "init-agent-volumes: agent volume permissions ready"
