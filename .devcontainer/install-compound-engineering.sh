#!/bin/bash
# Install the Compound Engineering plugin (EveryInc/compound-engineering-plugin)
# for Claude Code, Codex, and OpenCode inside the devcontainer.
#
# Ordering: this runs in postCreate BEFORE configure-llm-tools.sh, while the
# `claude` and `codex` binaries are still unwrapped. configure-llm-tools.sh
# later replaces them with wrappers that inject approval-bypass flags
# (--dangerously-skip-permissions / -a never -s danger-full-access) which are
# not valid alongside the `plugin` subcommand, so plugin management must happen
# first. configure-llm-tools.sh also writes the final ~/.config/opencode/
# opencode.json (with "permission": "allow"); the OpenCode plugin loads via its
# installed skill/agent/command directories, not via opencode.json, so letting
# configure-llm-tools.sh own that file afterward loses nothing.
#
# Every step is idempotent and non-fatal: a failure for one tool logs a warning
# and continues so plugin setup never blocks the rest of devcontainer creation.

set -uo pipefail
set -x
echo "[DEBUG] Starting install-compound-engineering.sh"

MARKETPLACE_SOURCE="EveryInc/compound-engineering-plugin"
MARKETPLACE_NAME="compound-engineering-plugin"
PLUGIN="compound-engineering"
BIN_WAIT_SECONDS="${COMPOUND_BIN_WAIT_SECONDS:-180}"
STEP_TIMEOUT="${COMPOUND_STEP_TIMEOUT:-180}"

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

# Wait up to BIN_WAIT_SECONDS for a CLI binary that a parallel postCreate step
# installs. With the current setup chain `claude` is installed immediately
# before this script, but `codex` comes from a parallel entry; this is the
# safety net for that lag. Returns non-zero if it never appears.
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
# Dependency: Bun (provides bunx)
# ============================================================================
# The @every-env/compound-plugin installer (Codex agents + OpenCode) runs via
# bunx. Install Bun globally if it is not already on PATH. Installed at create
# time (not in the Dockerfile) so it lands in the runtime nvm node prefix that
# the `node` devcontainer feature puts on PATH.
if ! command -v bunx >/dev/null 2>&1; then
  echo "[DEBUG] Installing Bun (required by @every-env/compound-plugin)..."
  run_step "Bun install" npm install -g bun
  hash -r
fi

# ============================================================================
# Claude Code
# ============================================================================
# Non-interactive equivalents of the /plugin marketplace add + /plugin install
# slash commands. State is written to the container-local ~/.claude named volume
# (persisted across rebuilds, not shared with the host).
if wait_for_bin claude; then
  echo "[DEBUG] Installing Compound Engineering for Claude Code..."
  run_step "Claude marketplace add" claude plugin marketplace add "$MARKETPLACE_SOURCE"
  run_step "Claude plugin install" claude plugin install "${PLUGIN}@${MARKETPLACE_NAME}"
else
  echo "WARNING: 'claude' binary not found after ${BIN_WAIT_SECONDS}s; skipping Claude plugin install." >&2
fi

# ============================================================================
# Codex
# ============================================================================
# Three steps: register the marketplace, install the plugin (skills), and
# install the delegated review/research/workflow agents via the Bun installer.
# Codex's native plugin spec does not register custom agents, so the bunx step
# is required in addition to `codex plugin add`.
if wait_for_bin codex; then
  echo "[DEBUG] Installing Compound Engineering for Codex..."
  run_step "Codex marketplace add" codex plugin marketplace add "$MARKETPLACE_SOURCE"
  run_step "Codex plugin add" codex plugin add "${PLUGIN}@${MARKETPLACE_NAME}"
  if command -v bunx >/dev/null 2>&1; then
    run_step "Codex agent install (bunx)" bunx @every-env/compound-plugin install "$PLUGIN" --to codex
    # The installer drops a timestamped config backup on every run; prune them
    # so they don't accumulate in the persisted volume across rebuilds.
    rm -f "$HOME"/.codex/config.toml.bak.* 2>/dev/null || true
  fi
else
  echo "WARNING: 'codex' binary not found after ${BIN_WAIT_SECONDS}s; skipping Codex plugin install." >&2
fi

# ============================================================================
# OpenCode
# ============================================================================
# Installs skills/agents/commands into ~/.config/opencode via the Bun installer.
# No `opencode` CLI subcommand is involved. configure-llm-tools.sh writes the
# final opencode.json afterward.
if command -v bunx >/dev/null 2>&1; then
  echo "[DEBUG] Installing Compound Engineering for OpenCode..."
  run_step "OpenCode plugin install (bunx)" bunx @every-env/compound-plugin install "$PLUGIN" --to opencode
  # configure-llm-tools.sh writes the canonical opencode.json afterward; prune
  # the installer's timestamped backups so they don't pile up in the volume.
  rm -f "$HOME"/.config/opencode/opencode.json.bak.* 2>/dev/null || true
else
  echo "WARNING: bunx unavailable; skipping OpenCode plugin install." >&2
fi

echo ""
echo "[DEBUG] Compound Engineering plugin installation complete."
echo "Installed for: Claude Code, Codex, OpenCode"
