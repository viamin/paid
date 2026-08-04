#!/bin/bash

# Install Ponytail for the agent CLIs whose state is persisted in devcontainer
# named volumes. Native CLI installers are used where available. Claude Code's
# documented installer is an interactive slash command, so this script mirrors
# Claude's local marketplace/cache metadata directly.

set -euo pipefail

PONYTAIL_REPO="${PONYTAIL_REPO:-https://github.com/DietrichGebert/ponytail.git}"
PONYTAIL_MARKETPLACE="${PONYTAIL_MARKETPLACE:-ponytail}"
PONYTAIL_PLUGIN="${PONYTAIL_PLUGIN:-ponytail}"
PONYTAIL_NPM_PACKAGE="${PONYTAIL_NPM_PACKAGE:-@dietrichgebert/ponytail}"
PONYTAIL_OMP_TARGET="${PONYTAIL_OMP_TARGET:-git:github.com/DietrichGebert/ponytail}"

wait_for_command() {
  local command_name="$1"
  local tries="${2:-60}"

  while [ "$tries" -gt 0 ]; do
    if command -v "$command_name" >/dev/null 2>&1; then
      return 0
    fi

    tries=$((tries - 1))
    sleep 2
  done

  return 1
}

install_claude_ponytail() {
  local claude_root="$HOME/.claude/plugins"
  local marketplace_dir="$claude_root/marketplaces/$PONYTAIL_MARKETPLACE"
  local manifest
  local version
  local cache_dir
  local commit_sha

  mkdir -p "$claude_root/marketplaces" "$claude_root/cache"

  if [ -d "$marketplace_dir/.git" ]; then
    git -C "$marketplace_dir" fetch --depth=1 origin main
    git -C "$marketplace_dir" checkout --quiet FETCH_HEAD
  elif [ -e "$marketplace_dir" ]; then
    echo "WARNING: $marketplace_dir exists but is not a git checkout; skipping Claude Ponytail install." >&2
    return 0
  else
    git clone --depth=1 "$PONYTAIL_REPO" "$marketplace_dir"
  fi

  manifest="$marketplace_dir/.claude-plugin/plugin.json"
  if [ ! -f "$manifest" ]; then
    echo "WARNING: Ponytail Claude manifest missing at $manifest; skipping Claude install." >&2
    return 0
  fi

  version="$(node -e 'console.log(require(process.argv[1]).version)' "$manifest")"
  commit_sha="$(git -C "$marketplace_dir" rev-parse HEAD)"
  cache_dir="$claude_root/cache/$PONYTAIL_MARKETPLACE/$PONYTAIL_PLUGIN/$version"

  mkdir -p "$cache_dir"
  find "$cache_dir" -mindepth 1 -maxdepth 1 -exec rm -r {} +
  git -C "$marketplace_dir" archive --format=tar HEAD | tar -x -C "$cache_dir"

  node - "$claude_root" "$PONYTAIL_REPO" "$marketplace_dir" "$cache_dir" "$version" "$commit_sha" <<'NODE'
const fs = require("fs");
const path = require("path");

const [root, repoUrl, marketplaceDir, cacheDir, version, commitSha] = process.argv.slice(2);
const knownPath = path.join(root, "known_marketplaces.json");
const installedPath = path.join(root, "installed_plugins.json");
const now = new Date().toISOString();

function readJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return fallback;
  }
}

function writeJson(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(data, null, 2)}\n`);
}

const known = readJson(knownPath, {});
known.ponytail = {
  source: { source: "github", repo: repoUrl.replace(/^https:\/\/github\.com\//, "").replace(/\.git$/, "") },
  installLocation: marketplaceDir,
  lastUpdated: now
};
writeJson(knownPath, known);

const installed = readJson(installedPath, { version: 2, plugins: {} });
installed.version ||= 2;
installed.plugins ||= {};
installed.plugins["ponytail@ponytail"] = [{
  scope: "user",
  installPath: cacheDir,
  version,
  installedAt: now,
  lastUpdated: now,
  gitCommitSha: commitSha
}];
writeJson(installedPath, installed);
NODE
}

install_codex_ponytail() {
  if ! wait_for_command codex; then
    echo "WARNING: codex command not found; skipping Codex Ponytail install." >&2
    return 0
  fi

  codex plugin marketplace add DietrichGebert/ponytail
  codex plugin add ponytail@ponytail
}

install_opencode_ponytail() {
  if ! wait_for_command opencode; then
    echo "WARNING: opencode command not found; skipping OpenCode Ponytail install." >&2
    return 0
  fi

  opencode plugin --global "$PONYTAIL_NPM_PACKAGE"
}

install_omp_ponytail() {
  if ! wait_for_command omp; then
    echo "WARNING: omp command not found; skipping OMP Ponytail install." >&2
    return 0
  fi

  omp plugin install "$PONYTAIL_OMP_TARGET"
}

echo "Installing Ponytail plugins for devcontainer agent CLIs..."
install_claude_ponytail
install_codex_ponytail
install_opencode_ponytail
install_omp_ponytail
echo "Ponytail plugin installation complete."
