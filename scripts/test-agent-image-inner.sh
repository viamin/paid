#!/bin/bash
# Inner test script executed inside the agent container.
# Extracted from test-agent-image.sh so shellcheck can lint it.
#
# Usage (called by test-agent-image.sh):
#   docker run --rm -v ./scripts/test-agent-image-inner.sh:/tmp/test.sh:ro IMAGE bash /tmp/test.sh

set -e

FAILURES=0

# check_tool verifies a CLI is installed and (optionally) runs a version check.
#   $1 - human-readable label
#   $2 - command name
#   $3 - version flag (default: --version)
#   $4 - "allow_failure" to tolerate a non-zero version exit (e.g. CLIs that require auth)
check_tool() {
    local label="$1"
    local command_name="$2"
    local version_args="${3:---version}"
    local allow_failure="${4:-}"

    echo "${label}:"
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        echo "   ERROR: ${command_name} is not installed"
        FAILURES=$((FAILURES + 1))
        return
    fi

    # Capture output and exit code separately so pipe to head doesn't mask failures.
    local output
    local rc=0
    # shellcheck disable=SC2086
    output=$("${command_name}" ${version_args} 2>&1) || rc=$?
    echo "   $(echo "${output}" | head -n 1)"

    if [ "$rc" -ne 0 ]; then
        if [ "${allow_failure}" = "allow_failure" ]; then
            echo "   (version check exited non-zero — allowed for CLIs that require auth)"
        else
            echo "   ERROR: ${command_name} ${version_args} failed (exit code ${rc})"
            FAILURES=$((FAILURES + 1))
        fi
    fi
}

echo "Testing installed tools..."
echo ""

echo "1. Git:"
git --version

echo ""
echo "2. Node.js:"
node --version

echo ""
echo "3. npm:"
npm --version

echo ""
echo "4. Ruby:"
ruby --version

echo ""
echo "5. Bundler:"
bundler --version

echo ""
echo "6. Python:"
python3 --version

echo ""
echo "7. Agent CLIs (allow auth-gated version failures):"
check_tool "   Claude Code CLI" claude --version allow_failure
check_tool "   OpenAI Codex CLI" codex --version allow_failure
check_tool "   Gemini CLI" gemini --version allow_failure
check_tool "   Kilocode CLI" kilo --version allow_failure

echo ""
echo "8. Developer tools (must succeed):"
check_tool "   ast-grep" ast-grep --version
check_tool "   scc" scc --version

echo ""
echo "9. User check (should be agent, not root):"
CURRENT_USER=$(whoami)
CURRENT_UID=$(id -u)
echo "   Current user: $CURRENT_USER (UID: $CURRENT_UID)"

if [ "$CURRENT_UID" -eq 0 ]; then
    echo "   ERROR: Running as root (UID 0), should be non-root user"
    FAILURES=$((FAILURES + 1))
fi

if [ "$CURRENT_USER" != "agent" ]; then
    echo "   ERROR: Running as ${CURRENT_USER}, expected agent"
    FAILURES=$((FAILURES + 1))
fi

if [ "$CURRENT_UID" -ne 0 ] && [ "$CURRENT_USER" = "agent" ]; then
    echo "   OK: Running as non-root user: agent"
fi

echo ""
echo "10. Workspace directory:"
ls -la /workspace
if [ -w /workspace ]; then
    echo "   /workspace is writable"
else
    echo "   ERROR: /workspace is not writable"
    FAILURES=$((FAILURES + 1))
fi

echo ""
if [ "$FAILURES" -gt 0 ]; then
    echo "FAILED: ${FAILURES} check(s) failed"
    exit 1
fi

echo "All tests passed!"
