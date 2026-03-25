#!/bin/bash
# Inner test script executed inside the agent container.
# Extracted from test-agent-image.sh so shellcheck can lint it and CI can reuse it cleanly.

FAILURES=0

check_tool() {
    local label="$1"
    local command_name="$2"
    local check_args="${3:---version}"

    echo "${label}:"
    if ! command -v "${command_name}" >/dev/null 2>&1; then
        echo "   ERROR: ${command_name} is not installed"
        FAILURES=$((FAILURES + 1))
        return
    fi

    local output
    local rc=0
    # shellcheck disable=SC2086
    output=$("${command_name}" ${check_args} 2>&1) || rc=$?

    printf '   %s\n' "$(printf '%s\n' "${output}" | head -n 1)"

    if [ "$rc" -ne 0 ]; then
        echo "   ERROR: ${command_name} ${check_args} failed (exit code ${rc})"
        FAILURES=$((FAILURES + 1))
    fi
}

echo "Testing installed tools..."
echo ""

echo "1. Core developer tools:"
check_tool "   Git" git --version
check_tool "   Node.js" node --version
check_tool "   npm" npm --version
check_tool "   Ruby" ruby --version
check_tool "   Bundler" bundler --version
check_tool "   Python" python3 --version
check_tool "   ast-grep" ast-grep --version
check_tool "   scc" scc --version

echo ""
echo "2. Agent CLIs:"
check_tool "   Claude Code CLI" claude --help
check_tool "   OpenAI Codex CLI" codex --help
check_tool "   Gemini CLI" gemini --help
check_tool "   Kilocode CLI" kilo --help

echo ""
echo "3. User check (should be agent, not root):"
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
echo "4. Workspace directory:"
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
