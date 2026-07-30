#!/bin/bash
# Install the Linked-Intent Development (LID) Claude Code plugins
# (jszmajda/lid) inside the devcontainer.
#
# LID is a methodology, not a tool. The workflow lives in CLAUDE.md
# (canonical; AGENTS.md is a symlink), which Codex, OpenCode, and Oh My Pi read
# natively — so for those tools no plugin install is needed. Claude Code is the
# richest integration and gets the auto-invoking skills via its plugin system.
#
# Ordering: this runs in postCreate BEFORE configure-llm-tools.sh, while the
# `claude` binary is still unwrapped. configure-llm-tools.sh later replaces it
# with a wrapper that injects --dangerously-skip-permissions, which is not
# valid alongside the `plugin` subcommand, so plugin management must happen
# first.
#
# Every step is idempotent and non-fatal: a failure logs a warning and
# continues so plugin setup never blocks the rest of devcontainer creation.

set -uo pipefail
set -x
echo "[DEBUG] Starting install-lid.sh"

MARKETPLACE_SOURCE="jszmajda/lid"
MARKETPLACE_NAME="jszmajda-lid"
CORE_PLUGINS=("linked-intent-dev" "arrow-maintenance")
# lid-experimental is opt-in; set INSTALL_LID_EXPERIMENTAL=1 to enable.
EXPERIMENTAL_PLUGIN="lid-experimental"
BIN_WAIT_SECONDS="${LID_BIN_WAIT_SECONDS:-180}"
STEP_TIMEOUT="${LID_STEP_TIMEOUT:-180}"

# Run a network/plugin step under a hard timeout, with stdin closed. This keeps
# container creation from hanging if a tool hits a first-run prompt on a fresh
# (empty) config volume or a network call stalls: </dev/null turns any prompt
# into immediate EOF, and `timeout` is the backstop. Always returns 0 (non-fatal)
# — on failure or timeout it logs a warning and the build continues.
run_step() {
  local desc="$1"
  shift
  if ! timeout -k 10 "$STEP_TIMEOUT" "$@" </dev/null; then
    echo "WARNING: ${desc} failed or timed out (${STEP_TIMEOUT}s); skipping." >&2
  fi
}

# Wait up to BIN_WAIT_SECONDS for the Claude CLI binary that the "setup" chain
# installs immediately before this script. Returns non-zero if it never appears.
wait_for_bin() {
  local bin="$1" waited=0
  while ! command -v "$bin" >/dev/null 2>&1; do
    if [ "$waited" -ge "$BIN_WAIT_SECONDS" ]; then
      return 1
    fi
    sleep 2
    waited=$((waited + 2))
  done
  return 0
}

# ============================================================================
# Claude Code
# ============================================================================
# Non-interactive equivalents of /plugin marketplace add + /plugin install.
# State is written to the container-local ~/.claude named volume (persisted
# across rebuilds, not shared with the host).
if wait_for_bin claude; then
  echo "[DEBUG] Registering LID marketplace for Claude Code..."
  run_step "Claude LID marketplace add" claude plugin marketplace add "$MARKETPLACE_SOURCE"
  for plugin in "${CORE_PLUGINS[@]}"; do
    echo "[DEBUG] Installing ${plugin} for Claude Code..."
    run_step "Claude plugin install ${plugin}" claude plugin install "${plugin}@${MARKETPLACE_NAME}"
  done
  if [ "${INSTALL_LID_EXPERIMENTAL:-0}" = "1" ]; then
    echo "[DEBUG] Installing ${EXPERIMENTAL_PLUGIN} (opt-in) for Claude Code..."
    run_step "Claude plugin install ${EXPERIMENTAL_PLUGIN}" claude plugin install "${EXPERIMENTAL_PLUGIN}@${MARKETPLACE_NAME}"
  fi
else
  echo "WARNING: 'claude' binary not found after ${BIN_WAIT_SECONDS}s; skipping LID plugin install." >&2
fi

echo ""
echo "[DEBUG] LID plugin installation complete."
echo "Installed for: Claude Code (Codex, OpenCode, Oh My Pi read CLAUDE.md/AGENTS.md natively)"
