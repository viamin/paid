# syntax=docker/dockerfile:1
# Agent container image for running AI coding assistants (Claude Code, Codex, Gemini CLI, etc.)
# This container provides an isolated environment for AI agents to execute code.

FROM ubuntu:24.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install base dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    curl \
    git \
    iptables \
    jq \
    unzip \
    wget \
    ca-certificates \
    gnupg \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

# Install Ruby build dependencies first so the expensive Ruby compile layer
# survives more image rebuilds when Node or PostgreSQL pins change later.
RUN apt-get update && apt-get install -y --no-install-recommends \
    autoconf \
    bison \
    libssl-dev \
    libreadline-dev \
    zlib1g-dev \
    libyaml-dev \
    libffi-dev \
    libgdbm-dev \
    rustc \
    && rm -rf /var/lib/apt/lists/*

# Install Ruby (pinned version for reproducible builds)
# Checksum from official release: https://www.ruby-lang.org/en/news/2025/12/17/ruby-3-4-8-released/
# Keep version in sync with .tool-versions
RUN RUBY_VERSION=3.4.8 \
    && EXPECTED_CHECKSUM="53c4ddad41fbb6189f1f5ee0db57a51d54bd1f87f8755b3d68604156a35b045b" \
    && TARBALL="ruby-${RUBY_VERSION}.tar.gz" \
    && curl -fsSLO "https://cache.ruby-lang.org/pub/ruby/${RUBY_VERSION%.*}/${TARBALL}" \
    && echo "${EXPECTED_CHECKSUM}  ${TARBALL}" | sha256sum -c - \
    && tar -xzf "${TARBALL}" \
    && cd "ruby-${RUBY_VERSION}" \
    && ./configure --disable-install-doc \
    && make -j"$(nproc)" \
    && make install \
    && cd .. \
    && rm -rf "ruby-${RUBY_VERSION}" "${TARBALL}"

# Remove some build-only dependencies to reduce image size and attack surface.
# We intentionally keep the corresponding *-dev packages (libssl-dev, libreadline-dev, zlib1g-dev,
# libyaml-dev, libffi-dev, libgdbm-dev, libpq-dev) so native extensions (e.g., Ruby gems like pg)
# can be compiled inside this agent image. We also keep postgresql-client-16 for schema dumps.
RUN apt-get update && apt-get purge -y --auto-remove \
    autoconf \
    bison \
    rustc \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 24.18.0 (pinned version for reproducible builds)
# Using direct download with pinned checksum verification for supply-chain security
# Checksums from official release: https://nodejs.org/download/release/v24.18.0/SHASUMS256.txt
# Keep version in sync with .tool-versions
RUN NODE_VERSION=24.18.0 \
    && DEB_ARCH="$(dpkg --print-architecture)" \
    && case "$DEB_ARCH" in \
        amd64) NODE_ARCH="x64"; EXPECTED_CHECKSUM="783130984963db7ba9cbd01089eaf2c2efb055c7c1693c943174b967b3050cb8" ;; \
        arm64) NODE_ARCH="arm64"; EXPECTED_CHECKSUM="6b4484c2190274175df9aa8f28e2d758a819cb1c1fe6ab481e2f95b463ab8508" ;; \
        *) echo "Unsupported architecture: $DEB_ARCH" >&2; exit 1 ;; \
    esac \
    && TARBALL="node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.gz" \
    && curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/${TARBALL}" \
    && echo "${EXPECTED_CHECKSUM}  ${TARBALL}" | sha256sum -c - \
    && tar -xzf "${TARBALL}" -C /usr/local --strip-components=1 \
    && rm "${TARBALL}"

# Install the PGDG apt repository so Ubuntu Noble can install the same pg_dump
# minor version as the pinned Postgres server image.
RUN install -d /usr/share/postgresql-common/pgdg \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
    && . /etc/os-release \
    && printf 'Types: deb\nURIs: https://apt.postgresql.org/pub/repos/apt\nSuites: %s-pgdg\nArchitectures: %s\nComponents: main\nSigned-By: /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc\n' "$VERSION_CODENAME" "$(dpkg --print-architecture)" > /etc/apt/sources.list.d/pgdg.sources

# Install runtime deps, Python, PostgreSQL client libs, and ShellCheck after Ruby
# so routine toolchain pin updates do not force a full Ruby recompilation.
# Keep client tools on the exact Postgres version shipped by the pinned server image.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq-dev \
    postgresql-client-16=16.15-1.pgdg24.04+2 \
    shellcheck \
    python3 \
    python3-pip \
    python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Install the Bundler version pinned in Gemfile.lock.
# BUNDLER_VERSION is extracted from Gemfile.lock's `BUNDLED WITH` at build time
# by scripts/build-agent-image.sh and .github/workflows/agent-image.yml so the
# agent image stays in lockstep with the app, devcontainer, and CI environments.
ARG BUNDLER_VERSION
RUN if [ -z "${BUNDLER_VERSION}" ]; then \
        echo "ERROR: BUNDLER_VERSION build-arg is required." >&2; \
        echo "Use scripts/build-agent-image.sh, which extracts it from Gemfile.lock's BUNDLED WITH." >&2; \
        exit 1; \
    fi \
    && gem install --no-document "bundler:${BUNDLER_VERSION}"

# Install agent-harness globally so lightweight utility scripts inside the
# agent container can use the same transport layer as the Rails app.
# AGENT_HARNESS_VERSION is extracted from Gemfile.lock at build time by
# scripts/build-agent-image.sh and .github/workflows/agent-image.yml so the
# agent image stays in lockstep with the control plane.
#
# When agent-harness is pinned to a git ref in Gemfile.lock (e.g. an
# unreleased upstream fix published as a commit), set AGENT_HARNESS_GIT_REF
# instead of AGENT_HARNESS_VERSION. The build then fetches only the pinned
# commit (a shallow, --depth 1 fetch so the full repository history is never
# downloaded), builds the .gem from source, and installs it. RubyGems has no
# `--git` install option, so the fetch-and-build pattern is the simplest way to
# install a gem straight from a git ref without invoking Bundler. The gemspec
# resolves its file list via `git ls-files`, so a checkout (which populates the
# index) is required rather than a bare tarball download.
ARG AGENT_HARNESS_VERSION
ARG AGENT_HARNESS_GIT_REF
RUN if [ -z "${AGENT_HARNESS_VERSION}" ] && [ -z "${AGENT_HARNESS_GIT_REF}" ]; then \
        echo "ERROR: AGENT_HARNESS_VERSION or AGENT_HARNESS_GIT_REF build-arg is required." >&2; \
        echo "Use scripts/build-agent-image.sh, which extracts it from Gemfile.lock." >&2; \
        exit 1; \
    fi \
    && if [ -n "${AGENT_HARNESS_GIT_REF}" ]; then \
        echo "Installing agent-harness from git ref: ${AGENT_HARNESS_GIT_REF}"; \
        mkdir -p /tmp/agent-harness-src \
        && cd /tmp/agent-harness-src \
        && git init \
        && git remote add origin "https://github.com/viamin/agent-harness.git" \
        && git fetch --depth 1 origin "${AGENT_HARNESS_GIT_REF}" \
        && git checkout FETCH_HEAD \
        && gem build agent-harness.gemspec \
        && gem install --no-document agent-harness-*.gem \
        && cd / \
        && rm -rf /tmp/agent-harness-src; \
    else \
        echo "Installing agent-harness version: ${AGENT_HARNESS_VERSION}"; \
        gem install --no-document "agent-harness:${AGENT_HARNESS_VERSION}"; \
    fi

# Install ruby-maat (VCS mining tool for churn/hotspot analysis)
# https://github.com/viamin/ruby-maat
# Version is sourced from Gemfile.lock at build time when RUBY_MAAT_VERSION is provided
# — see build-agent-image.sh and .github/workflows/agent-image.yml for the extraction logic.
ARG RUBY_MAAT_VERSION
RUN if [ -n "${RUBY_MAAT_VERSION}" ]; then \
        echo "Installing ruby-maat version ${RUBY_MAAT_VERSION} (from RUBY_MAAT_VERSION build-arg)"; \
        gem install --no-document "ruby-maat:${RUBY_MAAT_VERSION}"; \
    else \
        echo "RUBY_MAAT_VERSION not set; installing latest ruby-maat from RubyGems"; \
        gem install --no-document ruby-maat; \
    fi

# Install Yarn via corepack (pinned to match package.json)
# Set COREPACK_HOME to a shared location so the prepared Yarn version is
# accessible to the non-root agent user without re-downloading at runtime.
ENV COREPACK_HOME=/usr/local/share/corepack
RUN mkdir -p "$COREPACK_HOME" \
    && chmod 0777 "$COREPACK_HOME" \
    && corepack enable \
    && corepack prepare yarn@1.22.22 --activate

# Install ast-grep (AST-based code search/lint)
# https://github.com/ast-grep/ast-grep/releases
RUN AST_GREP_VERSION=0.45.1 \
    && DEB_ARCH="$(dpkg --print-architecture)" \
    && case "$DEB_ARCH" in \
        amd64) RUST_TRIPLE="x86_64-unknown-linux-gnu"; EXPECTED_CHECKSUM="76fb6555be6734fb5057dba8d2fb756430f374bb9e1af694cf1ce00e13238d63" ;; \
        arm64) RUST_TRIPLE="aarch64-unknown-linux-gnu"; EXPECTED_CHECKSUM="9ee7ec49aada3dc05135d21977af089a33fc3154ada25bab102daca90b5098f2" ;; \
        *) echo "Unsupported architecture: $DEB_ARCH" >&2; exit 1 ;; \
    esac \
    && ZIPFILE="app-${RUST_TRIPLE}.zip" \
    && curl -fsSL -o "${ZIPFILE}" "https://github.com/ast-grep/ast-grep/releases/download/${AST_GREP_VERSION}/${ZIPFILE}" \
    && echo "${EXPECTED_CHECKSUM}  ${ZIPFILE}" | sha256sum -c - \
    && unzip -o "${ZIPFILE}" ast-grep sg -d /usr/local/bin \
    && chmod +x /usr/local/bin/ast-grep /usr/local/bin/sg \
    && rm "${ZIPFILE}"

# Install scc (code line counter)
# https://github.com/boyter/scc/releases
RUN SCC_VERSION=3.7.0 \
    && DEB_ARCH="$(dpkg --print-architecture)" \
    && case "$DEB_ARCH" in \
        amd64) SCC_ARCH="x86_64"; EXPECTED_CHECKSUM="3d9d65b00ca874c2b29151abe7e1480736f5229edc3ce8e4b2791460cdfabf5a" ;; \
        arm64) SCC_ARCH="arm64"; EXPECTED_CHECKSUM="dcb05c6e993bb2d8d2da4765ff018f2e752325dd205a41698929c55e4123575d" ;; \
        *) echo "Unsupported architecture: $DEB_ARCH" >&2; exit 1 ;; \
    esac \
    && TARBALL="scc_Linux_${SCC_ARCH}.tar.gz" \
    && curl -fsSL -o "${TARBALL}" "https://github.com/boyter/scc/releases/download/v${SCC_VERSION}/${TARBALL}" \
    && echo "${EXPECTED_CHECKSUM}  ${TARBALL}" | sha256sum -c - \
    && tar -xzf "${TARBALL}" -C /usr/local/bin scc \
    && chmod +x /usr/local/bin/scc \
    && rm "${TARBALL}"

# Install rathole (preview tunnel client/server)
# https://github.com/rathole-org/rathole/releases
RUN RATHOLE_VERSION=0.5.0 \
    && DEB_ARCH="$(dpkg --print-architecture)" \
    && case "$DEB_ARCH" in \
        amd64) RATHOLE_ASSET="rathole-x86_64-unknown-linux-gnu.zip"; EXPECTED_CHECKSUM="3e7d0d0f365120cd3cd351d147d1a12ee960c8068b464d4dd533a3821873b80e" ;; \
        arm64) RATHOLE_ASSET="rathole-aarch64-unknown-linux-musl.zip"; EXPECTED_CHECKSUM="fa4a6fc63d86f8f1faa7c103a845e4715ce79a048455c0eec897b27237576564" ;; \
        *) echo "Unsupported architecture: $DEB_ARCH" >&2; exit 1 ;; \
    esac \
    && curl -fsSL -o "${RATHOLE_ASSET}" "https://github.com/rathole-org/rathole/releases/download/v${RATHOLE_VERSION}/${RATHOLE_ASSET}" \
    && echo "${EXPECTED_CHECKSUM}  ${RATHOLE_ASSET}" | sha256sum -c - \
    && unzip -j -o "${RATHOLE_ASSET}" rathole -d /usr/local/bin \
    && chmod +x /usr/local/bin/rathole \
    && rm "${RATHOLE_ASSET}"

# Install rtk (Rust Token Killer) for compressed AI agent shell output.
# rtk intercepts shell commands from AI agents and compresses the output 60-90%,
# reducing context window consumption.
# https://github.com/rtk-ai/rtk/releases
RUN RTK_VERSION=0.45.0 \
    && DEB_ARCH="$(dpkg --print-architecture)" \
    && case "$DEB_ARCH" in \
        amd64) RTK_ASSET="rtk-x86_64-unknown-linux-musl.tar.gz"; EXPECTED_CHECKSUM="c4c036fbf181fc55ef329786c8c17e0d427972b053b825944d968a6aafef1ba4" ;; \
        arm64) RTK_ASSET="rtk-aarch64-unknown-linux-gnu.tar.gz"; EXPECTED_CHECKSUM="80a746dd305ef944ff50ef011ae4ce3878dd5ba88dfe35d859d05498191637c3" ;; \
        *) echo "Unsupported architecture: $DEB_ARCH" >&2; exit 1 ;; \
    esac \
    && TARBALL="${RTK_ASSET}" \
    && curl -fsSL -o "${TARBALL}" "https://github.com/rtk-ai/rtk/releases/download/v${RTK_VERSION}/${RTK_ASSET}" \
    && echo "${EXPECTED_CHECKSUM}  ${TARBALL}" | sha256sum -c - \
    && tar -xzf "${TARBALL}" -C /usr/local/bin rtk \
    && chmod +x /usr/local/bin/rtk \
    && rm "${TARBALL}"

# Install CodeGraph for local-first code intelligence via MCP.
# Builds a code knowledge graph that agents query instead of grepping/reading
# files one at a time, reducing tool calls and tokens.
# Supply-chain hardening: --ignore-scripts — the package has no lifecycle scripts;
# platform-specific native binaries are resolved via npm optionalDependencies.
# https://github.com/colbymchenry/codegraph
RUN CODEGRAPH_VERSION=1.5.0 \
    && npm install -g --ignore-scripts "@colbymchenry/codegraph@${CODEGRAPH_VERSION}"

# Create non-root user for security before provider-specific setup. Keeping
# this separate from any one provider narrows the blast radius of future edits.
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /workspace /home/agent/.config /home/agent/.local/share \
    && chown -R agent:agent /workspace /home/agent

# Install Claude Code CLI via agent-harness install contract.
# The install command and post-install binary path are extracted from
# agent-harness at build time (see scripts/extract-runner-install-contract.rb)
# so Paid does not own the Claude-specific install recipe or version pin.
# The installer places the binary under $HOME/.local/ which is inaccessible to the
# non-root "agent" user. Copy the resolved binary to a system-wide path instead.
ARG CLAUDE_INSTALL_COMMAND
ARG CLAUDE_POST_INSTALL_BINARY_PATH
RUN if [ -z "${CLAUDE_INSTALL_COMMAND}" ]; then echo "ERROR: CLAUDE_INSTALL_COMMAND build-arg is required" >&2; exit 1; fi \
    && if [ -z "${CLAUDE_POST_INSTALL_BINARY_PATH}" ]; then echo "ERROR: CLAUDE_POST_INSTALL_BINARY_PATH build-arg is required" >&2; exit 1; fi \
    && eval "${CLAUDE_INSTALL_COMMAND}" \
    && cp -L "$(eval echo "${CLAUDE_POST_INSTALL_BINARY_PATH}")" /usr/local/bin/claude \
    && chmod +x /usr/local/bin/claude

# Install agent CLI tools via npm.
# All versions are pinned for reproducible builds; update intentionally.
# --ignore-scripts on every install: supply-chain hardening — prevents npm
# lifecycle scripts (postinstall, preinstall) from executing arbitrary code.
# See: https://www.elastic.co/security-labs/axios-one-rat-to-rule-them-all

# Codex CLI: version is owned by agent-harness (installation_contract).
# CODEX_PACKAGE is extracted from agent-harness at build time by
# build-agent-image.sh / agent-image.yml — Paid no longer pins this version.
ARG CODEX_PACKAGE
RUN if [ -z "${CODEX_PACKAGE}" ]; then \
        echo "ERROR: CODEX_PACKAGE build-arg is required (sourced from agent-harness)" >&2; \
        exit 1; \
    fi \
    && npm install -g --ignore-scripts "${CODEX_PACKAGE}"

# Gemini CLI version is owned by agent-harness; the install command is extracted
# at build time by scripts/build-agent-image.sh and passed as a build arg.
# Supply-chain hardening: enforce --ignore-scripts regardless of what the
# contract returns, matching the policy applied to every other npm install above.
ARG GEMINI_CLI_INSTALL_COMMAND
RUN if [ -z "${GEMINI_CLI_INSTALL_COMMAND}" ]; then \
        echo "ERROR: GEMINI_CLI_INSTALL_COMMAND not set; aborting build" >&2; \
        exit 1; \
    fi \
    && case "${GEMINI_CLI_INSTALL_COMMAND}" in \
        *--ignore-scripts*) ;; \
        *) echo "ERROR: GEMINI_CLI_INSTALL_COMMAND must include --ignore-scripts for supply-chain safety" >&2; exit 1 ;; \
    esac \
    && echo "Installing Gemini CLI via agent-harness contract: ${GEMINI_CLI_INSTALL_COMMAND}" \
    && eval "${GEMINI_CLI_INSTALL_COMMAND}"

# Kilocode CLI: version is owned by agent-harness (installation_contract).
# KILOCODE_INSTALL_COMMAND is extracted from agent-harness at build time by
# build-agent-image.sh / agent-image.yml — Paid no longer pins this version.
# Supply-chain hardening: enforce --ignore-scripts regardless of what the
# contract returns, matching the policy applied to every other npm install above.
ARG KILOCODE_INSTALL_COMMAND
RUN if [ -z "${KILOCODE_INSTALL_COMMAND}" ]; then \
        echo "ERROR: KILOCODE_INSTALL_COMMAND not set; aborting build" >&2; \
        exit 1; \
    fi \
    && case "${KILOCODE_INSTALL_COMMAND}" in \
        *--ignore-scripts*) ;; \
        *) echo "ERROR: KILOCODE_INSTALL_COMMAND must include --ignore-scripts for supply-chain safety" >&2; exit 1 ;; \
    esac \
    && echo "Installing Kilocode CLI via agent-harness contract: ${KILOCODE_INSTALL_COMMAND}" \
    && eval "${KILOCODE_INSTALL_COMMAND}"

# Pre-seed the Kilocode SQLite database so the first container invocation does
# not run "Performing one time database migration, may take a few minutes..."
# inside the runner smoke preflight, where it exceeds the preflight wall-clock
# timeout and exhausts the runner (the original symptom: exit 137 after a 60s
# preflight timeout). The migration is a local SQLite operation that runs on
# first `kilo run` regardless of model auth, so warming needs no credentials.
#
# `kilo run` opens an interactive session that never exits on its own, so we
# cap it with `timeout`, which cleanly terminates kilo and its child binary
# once the migration has had time to run (verified: no orphaned processes, DB
# fully migrated). We deliberately do NOT pattern-kill "kilo": this RUN's own
# shell argv contains "kilo", so `pkill -f kilo` would also kill the build
# shell. The window is generous — the migration was ~60s on a heavily loaded
# runtime host, and build hosts are far less contended — and `timeout` always
# runs the full window because the session never exits. The next RUN fails
# loudly if the migrated DB is absent, rather than shipping a regressed
# (unwarmed) image. Mirrors the OpenCode pre-seed below.
#
# The pre-seeded DB is copied to /opt/kilo-seed so it survives the tmpfs mount
# that Provision#host_config places at /home/agent/.local/share/kilo at
# runtime. Containers::Provision#seed_kilo_database! restores it from /opt into
# the tmpfs after the container starts.
USER agent
RUN mkdir -p /home/agent/.local/share/kilo \
    && timeout -k 10s 120s kilo run "OK" > /dev/null 2>&1 || true
USER root
RUN test -f /home/agent/.local/share/kilo/kilo.db \
    && mkdir -p /opt/kilo-seed \
    && cp -a /home/agent/.local/share/kilo/. /opt/kilo-seed/ \
    && chown -R agent:agent /opt/kilo-seed

# OpenCode CLI: install recipe and version are owned by agent-harness
# (installation_contract). OPENCODE_INSTALL_COMMAND is extracted from
# agent-harness at build time by build-agent-image.sh / agent-image.yml —
# Paid no longer pins the version or install recipe.
#
# Supply-chain hardening: enforce --ignore-scripts regardless of what the
# contract returns, matching the policy applied to every other npm install above.
# The contract's required postinstall (extracting OpenCode's native binary)
# is appended explicitly so OpenCode can start without re-running the
# extraction on every container invocation — without that, the first `opencode
# run` in a fresh tmpfs pays the binary download/extract cost inside the
# runner smoke preflight and gets SIGKILLed (exit 137) by the OOM killer or
# the preflight wall-clock timeout (the original symptom: opencode preflight
# killed by exit 137 on every attempt — see #2913).
ARG OPENCODE_INSTALL_COMMAND
RUN if [ -z "${OPENCODE_INSTALL_COMMAND}" ]; then \
        echo "ERROR: OPENCODE_INSTALL_COMMAND build-arg is required (sourced from agent-harness)" >&2; \
        exit 1; \
    fi \
    && case "${OPENCODE_INSTALL_COMMAND}" in \
        *--ignore-scripts*) ;; \
        *) echo "ERROR: OPENCODE_INSTALL_COMMAND must include --ignore-scripts for supply-chain safety" >&2; exit 1 ;; \
    esac \
    && echo "Installing OpenCode CLI via agent-harness contract: ${OPENCODE_INSTALL_COMMAND}" \
    && eval "${OPENCODE_INSTALL_COMMAND}"

# Pre-seed the OpenCode SQLite database so the first container invocation does
# not emit "Performing one time database migration, may take a few minutes..."
# inside the runner smoke preflight, where it exceeds the preflight wall-clock
# timeout and exhausts the runner (the original symptom: exit 137 after a 60s
# preflight timeout). The migration is a local SQLite operation that runs on
# first `opencode run` regardless of model auth, so warming needs no credentials.
#
# `opencode run` opens an interactive session that never exits on its own, so
# we cap it with `timeout`, which cleanly terminates opencode and its child
# binary once the migration has had time to run (verified: no orphaned
# processes, DB fully migrated). We deliberately do NOT pattern-kill "opencode":
# this RUN's own shell argv contains "opencode", so `pkill -f opencode` would
# also kill the build shell. The window is generous — the migration was ~60s
# on a heavily loaded runtime host, and build hosts are far less contended —
# and `timeout` always runs the full window because the session never exits.
# The next RUN fails loudly if the migrated DB is absent, rather than
# shipping a regressed (unwarmed) image. Mirrors the Kilocode pre-seed above.
#
# The pre-seeded DB is copied to /opt/opencode-seed so it survives the tmpfs
# mount that Provision#host_config places at /home/agent/.local/share/opencode
# at runtime. Containers::Provision#seed_opencode_database! restores it from
# /opt into the tmpfs after the container starts.
USER agent
RUN mkdir -p /home/agent/.local/share/opencode \
    && timeout -k 10s 120s opencode run "OK" > /dev/null 2>&1 || true
USER root
RUN test -f /home/agent/.local/share/opencode/opencode.db \
    && mkdir -p /opt/opencode-seed \
    && cp -a /home/agent/.local/share/opencode/. /opt/opencode-seed/ \
    && chown -R agent:agent /opt/opencode-seed

# Pi CLI: version is owned by agent-harness (installation_contract).
# PI_PACKAGE is extracted from agent-harness at build time by
# build-agent-image.sh / agent-image.yml — Paid no longer pins this version.
ARG PI_PACKAGE
RUN if [ -z "${PI_PACKAGE}" ]; then \
        echo "ERROR: PI_PACKAGE build-arg is required (sourced from agent-harness)" >&2; \
        exit 1; \
    fi \
    && npm install -g --ignore-scripts "${PI_PACKAGE}"

# Install Oh My Pi plus its Bun runtime from the agent-harness contract.
# @spec CONTAINER-RUNTIME-030
# OMP's install command is owned by agent-harness; Paid can redirect its temp
# files for CI stability, but must not change which dependencies the contract
# installs or the resulting CLI shape can drift from the runner contract.
ARG OMP_PACKAGE
ARG OMP_INSTALL_COMMAND
ARG OMP_BUN_VERSION
ARG OMP_BUN_INSTALL_SCRIPT_URL
RUN if [ -z "${OMP_PACKAGE}" ]; then \
        echo "ERROR: OMP_PACKAGE build-arg is required (sourced from agent-harness)" >&2; \
        exit 1; \
    fi \
    && if [ -z "${OMP_INSTALL_COMMAND}" ]; then \
        echo "ERROR: OMP_INSTALL_COMMAND build-arg is required (sourced from agent-harness)" >&2; \
        exit 1; \
    fi \
    && if [ -z "${OMP_BUN_VERSION}" ]; then \
        echo "ERROR: OMP_BUN_VERSION build-arg is required (sourced from agent-harness)" >&2; \
        exit 1; \
    fi \
    && if [ -z "${OMP_BUN_INSTALL_SCRIPT_URL}" ]; then \
        echo "ERROR: OMP_BUN_INSTALL_SCRIPT_URL build-arg is required (sourced from agent-harness)" >&2; \
        exit 1; \
    fi \
    && export BUN_INSTALL="/usr/local/bun" \
    && mkdir -p "${BUN_INSTALL}/bin" \
    && curl -fsSL "${OMP_BUN_INSTALL_SCRIPT_URL}" -o /tmp/omp-bun-install.sh \
    && test -s /tmp/omp-bun-install.sh \
    && BUN_VERSION="${OMP_BUN_VERSION}" bash /tmp/omp-bun-install.sh \
    && rm -f /tmp/omp-bun-install.sh \
    && test -x "${BUN_INSTALL}/bin/bun" \
    && ln -sf "${BUN_INSTALL}/bin/bun" "${BUN_INSTALL}/bin/bunx" \
    && export PATH="${BUN_INSTALL}/bin:${PATH}" \
    && ln -sf "${BUN_INSTALL}/bin/bun" /usr/local/bin/bun \
    && ln -sf "${BUN_INSTALL}/bin/bunx" /usr/local/bin/bunx \
    && export OMP_INSTALL_WORKDIR="/var/tmp/omp-install" \
    && export OMP_INSTALL_TMPDIR="${OMP_INSTALL_WORKDIR}/tmp" \
    && mkdir -p "${OMP_INSTALL_WORKDIR}/cache" "${OMP_INSTALL_TMPDIR}" \
    && TMPDIR="${OMP_INSTALL_TMPDIR}" TMP="${OMP_INSTALL_TMPDIR}" TEMP="${OMP_INSTALL_TMPDIR}" \
       npm_config_tmp="${OMP_INSTALL_TMPDIR}" npm_config_cache="${OMP_INSTALL_WORKDIR}/cache" \
       sh -c "${OMP_INSTALL_COMMAND}" \
    && rm -rf "${OMP_INSTALL_WORKDIR}" \
    && OMP_BINARY_PATH="$(command -v omp || true)" \
    && if [ -z "${OMP_BINARY_PATH}" ]; then \
        echo "ERROR: omp binary not found on PATH after install" >&2; \
        echo "PATH=${PATH}" >&2; \
        echo "TMPDIR=${TMPDIR:-unset}" >&2; \
        echo "npm prefix: $(npm config get prefix)" >&2; \
        echo "npm root -g: $(npm root -g)" >&2; \
        ls -la "$(npm config get prefix)/bin" >&2 || true; \
        exit 1; \
    fi \
    && if [ ! -x "${OMP_BINARY_PATH}" ]; then \
        echo "ERROR: omp binary is not executable: ${OMP_BINARY_PATH}" >&2; \
        ls -l "${OMP_BINARY_PATH}" >&2 || true; \
        exit 1; \
    fi \
    && OMP_BUN_ACTUAL_VERSION="$(bun --version || true)" \
    && if [ "${OMP_BUN_ACTUAL_VERSION}" != "${OMP_BUN_VERSION}" ]; then \
        echo "ERROR: bun version mismatch after OMP install (expected ${OMP_BUN_VERSION}, got ${OMP_BUN_ACTUAL_VERSION:-missing})" >&2; \
        command -v bun >&2 || true; \
        ls -l /usr/local/bin/bun >&2 || true; \
        exit 1; \
    fi

# Install GitHub Copilot CLI via agent-harness install contract.
# The modern `copilot` binary supports --autopilot mode for fully autonomous,
# non-interactive agent execution. Install recipe is owned by agent-harness.
# Supply-chain hardening: enforce --ignore-scripts regardless of what the
# contract returns, matching the policy applied to every other npm install above.
ARG COPILOT_INSTALL_COMMAND
RUN if [ -z "${COPILOT_INSTALL_COMMAND}" ]; then \
        echo "ERROR: COPILOT_INSTALL_COMMAND build-arg is required (sourced from agent-harness)" >&2; \
        exit 1; \
    fi \
    && case "${COPILOT_INSTALL_COMMAND}" in \
        *--ignore-scripts*) ;; \
        *) echo "ERROR: COPILOT_INSTALL_COMMAND must include --ignore-scripts for supply-chain safety" >&2; exit 1 ;; \
    esac \
    && echo "Installing GitHub Copilot CLI via agent-harness contract: ${COPILOT_INSTALL_COMMAND}" \
    && eval "${COPILOT_INSTALL_COMMAND}"

# Install Cursor agent CLI via agent-harness install contract.
# agent-harness owns the artifact URL, checksum pin, and binary metadata.
# These values are extracted at build time (see scripts/extract-runner-install-contract.rb)
# so Paid does not own the Cursor-specific install recipe or version pin.
# The artifact tarball is downloaded directly (more stable than the install script
# whose checksum changes frequently) and verified against agent-harness's pinned SHA256.
ARG CURSOR_ARTIFACT_URL
ARG CURSOR_ARTIFACT_SHA256
ARG CURSOR_BINARY_NAME=cursor-agent
ARG CURSOR_GLOBAL_PATH=/usr/local/bin/cursor-agent
RUN if [ -z "${CURSOR_ARTIFACT_URL}" ]; then echo "ERROR: CURSOR_ARTIFACT_URL build-arg is required" >&2; exit 1; fi \
    && if [ -z "${CURSOR_ARTIFACT_SHA256}" ]; then echo "ERROR: CURSOR_ARTIFACT_SHA256 build-arg is required" >&2; exit 1; fi \
    && curl -fsSL "${CURSOR_ARTIFACT_URL}" -o /tmp/cursor-artifact.tar.gz \
    && echo "${CURSOR_ARTIFACT_SHA256}  /tmp/cursor-artifact.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/cursor-artifact.tar.gz -C /tmp \
    && mkdir -p /opt/cursor-agent "$(dirname "${CURSOR_GLOBAL_PATH}")" \
    && cp -R /tmp/dist-package/. /opt/cursor-agent/ \
    && test -f "/opt/cursor-agent/${CURSOR_BINARY_NAME}" \
    && chmod +x "/opt/cursor-agent/${CURSOR_BINARY_NAME}" \
    && ln -sf "/opt/cursor-agent/${CURSOR_BINARY_NAME}" "${CURSOR_GLOBAL_PATH}" \
    && rm -rf /tmp/cursor-artifact.tar.gz /tmp/dist-package

# Install git credential helper for proxy-based authentication.
# This allows git clone/push inside the container without exposing GitHub tokens.
COPY docker/agent/scripts/git-credential-paid /usr/local/bin/git-credential-paid
COPY docs/lid /opt/paid-lid/docs/lid
COPY bin/coherence-check.mjs /opt/paid-lid/bin/coherence-check.mjs
RUN chmod +x /usr/local/bin/git-credential-paid
RUN chmod +x /opt/paid-lid/bin/coherence-check.mjs

# Configure git at system level so it works with ReadonlyRootfs.
# The credential helper fetches tokens from the secrets proxy on demand.
RUN git config --system init.defaultBranch main \
    && git config --system credential.helper /usr/local/bin/git-credential-paid

# Set up working directory
WORKDIR /workspace

# Switch to non-root user
USER agent

# Default command (overridden at runtime)
CMD ["bash"]
