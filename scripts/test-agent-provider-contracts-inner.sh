#!/bin/bash
# Provider-contract smoke test executed inside the paid-agent container.
# Validates that every provider declared container-executable in Paid has a
# compatible CLI installed in the image, and that known non-runnable providers
# (e.g. copilot) are not accidentally promoted to container-executable.
#
# Also performs a cheap Codex config.toml shape check to catch notify/TOML
# regressions without requiring real credentials or model calls.
#
# Usage (called by test-agent-provider-contracts.sh):
#   docker run --rm \
#     -v ./scripts/test-agent-provider-contracts-inner.sh:/tmp/contract-test.sh:ro \
#     -e CONTAINER_EXECUTABLE_KEYS="aider claude codex cursor gemini kilocode opencode" \
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
# 1. CLI binary mapping — provider key → expected binary name
# ---------------------------------------------------------------------------
# This mapping must stay in sync with docker/agent/Dockerfile installs.
declare -A PROVIDER_CLI_BINARY
PROVIDER_CLI_BINARY=(
    [aider]=aider
    [claude]=claude
    [codex]=codex
    [cursor]=cursor-agent
    [gemini]=gemini
    [kilocode]=kilo
    [opencode]=opencode
)

echo "=== Provider-contract smoke test ==="
echo ""

# ---------------------------------------------------------------------------
# 2. Every container-executable provider must have its CLI installed
# ---------------------------------------------------------------------------
echo "1. Container-executable provider CLI checks:"

IFS=' ' read -r -a EXEC_KEYS <<< "${CONTAINER_EXECUTABLE_KEYS}"

for key in "${EXEC_KEYS[@]}"; do
    binary="${PROVIDER_CLI_BINARY[$key]:-}"
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
# 3. Known non-runnable providers must NOT be container-executable
# ---------------------------------------------------------------------------
echo "2. Non-runnable provider exclusion checks:"

# Copilot CLI only supports shell/git/gh assist subcommands, not repo-changing
# agent tasks. It must not appear in the container-executable set.
COPILOT_FOUND=false
for key in "${EXEC_KEYS[@]}"; do
    if [ "$key" = "copilot" ]; then
        COPILOT_FOUND=true
        break
    fi
done

if [ "$COPILOT_FOUND" = "true" ]; then
    fail "copilot must not be in CONTAINER_EXECUTABLE_PROVIDER_KEYS"
else
    pass "copilot correctly excluded from container-executable set"
fi

echo ""

# ---------------------------------------------------------------------------
# 4. Codex config.toml shape validation
# ---------------------------------------------------------------------------
echo "3. Codex config.toml shape validation:"

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

echo "All provider-contract checks passed!"
