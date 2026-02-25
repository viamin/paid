#!/bin/bash
# Wrapper for ssh-keygen signing that uses 1Password's SSH agent socket
# when available, bypassing VS Code's forwarded agent proxy which doesn't
# support data signing operations (ssh-keygen -Y sign).
#
# Falls back to the existing SSH_AUTH_SOCK (e.g. VS Code's forwarded agent)
# if the 1Password socket is present but not responding.

OP_AGENT_SOCK="/home/vscode/.1password/agent.sock"

if [ -S "$OP_AGENT_SOCK" ] && SSH_AUTH_SOCK="$OP_AGENT_SOCK" ssh-add -l >/dev/null 2>&1; then
  export SSH_AUTH_SOCK="$OP_AGENT_SOCK"
fi

exec ssh-keygen "$@"
