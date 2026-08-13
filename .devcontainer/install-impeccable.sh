#!/bin/bash

# Install Impeccable skills for the devcontainer agent CLIs.

set -euo pipefail

IMPECCABLE_PACKAGE="${IMPECCABLE_PACKAGE:-impeccable@3.5.0}"
IMPECCABLE_PROVIDERS="${IMPECCABLE_PROVIDERS:-claude,codex,opencode,pi}"
IMPECCABLE_SCOPE="${IMPECCABLE_SCOPE:-global}"
STEP_TIMEOUT="${IMPECCABLE_STEP_TIMEOUT:-300}"

if ! command -v npx >/dev/null 2>&1; then
  echo "WARNING: npx command not found; skipping Impeccable install." >&2
  exit 0
fi

echo "Installing Impeccable skills for devcontainer agent CLIs..."
if ! timeout -k 10 "$STEP_TIMEOUT" npx --yes "$IMPECCABLE_PACKAGE" install \
  --providers="$IMPECCABLE_PROVIDERS" \
  --scope="$IMPECCABLE_SCOPE" </dev/null; then
  echo "WARNING: Impeccable install failed or timed out (${STEP_TIMEOUT}s); skipping." >&2
  exit 0
fi

echo "Impeccable installation complete."
