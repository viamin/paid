#!/usr/bin/env bash
# Build a container-owned global git config seeded with ONLY the host's
# committer identity (user.name / user.email).
#
# The host ~/.gitconfig is bind-mounted read-only at ~/.gitconfig.host purely as
# a seed. We deliberately do NOT use it as the container's global config because
# it carries host-specific settings — notably 1Password SSH signing
# (gpg.ssh.program=/Applications/1Password.app/...) — that do not exist in this
# Linux container and break any commit made outside the repo-local config
# (e.g. the throwaway worktrees created by specs).
#
# Commit signing inside this repo is configured separately and repo-locally by
# setup-signing-key.sh, so nothing host-specific needs to flow through here.
set -euo pipefail

SEED="${HOME}/.gitconfig.host"
TARGET="${GIT_CONFIG_GLOBAL:-${HOME}/.gitconfig}"

# Start from an empty, container-owned global config.
: > "${TARGET}"

if [[ -r "${SEED}" ]]; then
  name="$(git config --file "${SEED}" --get user.name || true)"
  email="$(git config --file "${SEED}" --get user.email || true)"
  # Use explicit if-blocks (not `[[ ... ]] && cmd`) so a missing value can never
  # short-circuit into a non-zero script exit under `set -e`.
  if [[ -n "${name}" ]]; then
    git config --file "${TARGET}" user.name "${name}"
  fi
  if [[ -n "${email}" ]]; then
    git config --file "${TARGET}" user.email "${email}"
  fi
fi

echo "Container global git config written to ${TARGET}:"
git config --file "${TARGET}" --list || true
