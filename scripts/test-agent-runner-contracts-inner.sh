#!/bin/bash
# Runner-contract smoke test executed inside the paid-agent container.
# Validates that every runner declared container-executable in Paid has a
# compatible CLI installed in the image.
#
# Also performs a cheap Codex config.toml shape check to catch notify/TOML
# regressions without requiring real credentials or model calls.
#
# Usage (called by test-agent-runner-contracts.sh):
#   docker run --rm \
#     -v ./scripts/test-agent-runner-contracts-inner.sh:/tmp/contract-test.sh:ro \
#     -e CONTAINER_EXECUTABLE_KEYS="claude codex cursor gemini kilocode opencode openrouter_free pi" \
#     -e CODEX_NOTIFY_LINE='notify = ["sh", "-lc", "date +%s > /workspace/.paid-heartbeat"]' \
#     -e CODEX_CONFIG_TOML_BODY='[chatgpt]...' \
#     paid-agent:latest bash /tmp/contract-test.sh

set -euo pipefail

FAILURES=0

fail() {
    echo "   FAIL: $1"
    FAILURES=$((FAILURES + 1))
}

pass() {
    echo "   OK: $1"
}

# ---------------------------------------------------------------------------
# 1. CLI binary mapping — runner key → expected binary name
# ---------------------------------------------------------------------------
# This mapping must stay in sync with docker/agent/Dockerfile installs.
declare -A RUNNER_CLI_BINARY
RUNNER_CLI_BINARY=(
    [claude]=claude
    [codex]=codex
    [copilot]=copilot
    [cursor]=cursor-agent
    [gemini]=gemini
    [kilocode]=kilo
    [opencode]=opencode
    [openrouter_free]=opencode
    [openrouter_pareto]=opencode
    [pi]=pi
)

echo "=== Runner-contract smoke test ==="
echo ""

# ---------------------------------------------------------------------------
# 2. Every container-executable runner must have its CLI installed
# ---------------------------------------------------------------------------
echo "1. Container-executable runner CLI checks:"

IFS=' ' read -r -a EXEC_KEYS <<< "${CONTAINER_EXECUTABLE_KEYS}"

for key in "${EXEC_KEYS[@]}"; do
    binary="${RUNNER_CLI_BINARY[$key]:-}"
    if [ -z "$binary" ]; then
        fail "${key}: no CLI binary mapping defined in test"
        continue
    fi

    if command -v "$binary" >/dev/null 2>&1; then
        pass "${key} → ${binary} found at $(command -v "$binary")"
    else
        fail "${key} → ${binary} not found in PATH"
    fi
done

echo ""

# ---------------------------------------------------------------------------
# 3. Codex config.toml shape validation
# ---------------------------------------------------------------------------
echo "2. Codex config.toml shape validation:"

CODEX_NOTIFY_LINE="${CODEX_NOTIFY_LINE:-}"
CODEX_CONFIG_TOML_BODY="${CODEX_CONFIG_TOML_BODY:-}"

if [ -z "$CODEX_NOTIFY_LINE" ] || [ -z "$CODEX_CONFIG_TOML_BODY" ]; then
    fail "CODEX_NOTIFY_LINE or CODEX_CONFIG_TOML_BODY not provided"
else
    # Assemble the full config as Paid does: notify line + blank line + TOML body
    FULL_CONFIG="${CODEX_NOTIFY_LINE}

${CODEX_CONFIG_TOML_BODY}"

    CONFIG_DIR="/home/agent/.codex"
    CONFIG_FILE="${CONFIG_DIR}/config.toml"
    mkdir -p "$CONFIG_DIR"
    printf '%s\n' "$FULL_CONFIG" > "$CONFIG_FILE"

    # Verify the file was written and is non-empty
    if [ ! -s "$CONFIG_FILE" ]; then
        fail "config.toml is empty after write"
    else
        pass "config.toml written ($(wc -c < "$CONFIG_FILE") bytes)"
    fi

    # Validate notify is a TOML array of strings (basic shape check)
    if echo "$CODEX_NOTIFY_LINE" | grep -qE '^notify\s*=\s*\['; then
        pass "notify line starts with 'notify = ['"
    else
        fail "notify line has unexpected shape: ${CODEX_NOTIFY_LINE}"
    fi

    # Validate the TOML body has a [chatgpt] section header
    if echo "$CODEX_CONFIG_TOML_BODY" | grep -qE '^\[chatgpt\]'; then
        pass "config body contains [chatgpt] section"
    else
        fail "config body missing [chatgpt] section"
    fi

    # If codex CLI is available, run a config validation check
    if command -v codex >/dev/null 2>&1; then
        # codex --help should still work even with the config present
        if codex --help >/dev/null 2>&1; then
            pass "codex --help succeeds with generated config in place"
        else
            fail "codex --help failed with generated config in place"
        fi
    fi
fi

echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [ "$FAILURES" -gt 0 ]; then
    echo "FAILED: ${FAILURES} contract check(s) failed"
    exit 1
fi

echo "All runner-contract checks passed!"
