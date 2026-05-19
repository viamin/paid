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

# Install Node.js 22.13.0 (pinned version for reproducible builds)
# Using direct download with pinned checksum verification for supply-chain security
# Checksums from official release: https://nodejs.org/download/release/v22.13.0/SHASUMS256.txt
# Keep version in sync with .tool-versions
RUN NODE_VERSION=22.13.0 \
    && DEB_ARCH="$(dpkg --print-architecture)" \
    && case "$DEB_ARCH" in \
        amd64) NODE_ARCH="x64"; EXPECTED_CHECKSUM="9a33e89093a0d946c54781dcb3ccab4ccf7538a7135286528ca41ca055e9b38f" ;; \
        arm64) NODE_ARCH="arm64"; EXPECTED_CHECKSUM="e0cc088cb4fb2e945d3d5c416c601e1101a15f73e0f024c9529b964d9f6dce5b" ;; \
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
    postgresql-client-16=16.14-1.pgdg24.04+1 \
    shellcheck \
    python3 \
    python3-pip \
    python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Install Bundler (pinned to match Gemfile.lock)
RUN gem install --no-document bundler:4.0.11

# Install agent-harness globally so lightweight utility scripts inside the
# agent container can use the same transport layer as the Rails app.
# Keep this pin in sync with Gemfile.lock until the image build is wired to a
# shared source of truth.
RUN gem install --no-document agent-harness:0.18.2

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
RUN AST_GREP_VERSION=0.42.1 \
    && DEB_ARCH="$(dpkg --print-architecture)" \
    && case "$DEB_ARCH" in \
        amd64) RUST_TRIPLE="x86_64-unknown-linux-gnu"; EXPECTED_CHECKSUM="5de8b87cba67fc8dc3e239d54b6484802ad745a7ae3de76be4fe89661dc52657" ;; \
        arm64) RUST_TRIPLE="aarch64-unknown-linux-gnu"; EXPECTED_CHECKSUM="3ba383839044cf9817929435f5ce0027f91d06931e8efb32d942e58d73d92be5" ;; \
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

# OpenCode CLI: version is owned by agent-harness (installation_contract).
# OPENCODE_PACKAGE is extracted from agent-harness at build time by
# build-agent-image.sh / agent-image.yml — Paid no longer pins this version.
ARG OPENCODE_PACKAGE
RUN if [ -z "${OPENCODE_PACKAGE}" ]; then \
        echo "ERROR: OPENCODE_PACKAGE build-arg is required (sourced from agent-harness)" >&2; \
        exit 1; \
    fi \
    && npm install -g --ignore-scripts "${OPENCODE_PACKAGE}"

# Pre-seed the OpenCode SQLite database so the first container invocation does
# not emit "Performing one time database migration, may take a few minutes..."
# into stdout, which breaks the Test Agent ping response matching.
# The opencode binary creates its DB on first run; this step discards the
# network-dependent output and only keeps the migrated SQLite file.
#
# The pre-seeded DB is copied to /opt/opencode-seed so it survives the tmpfs
# mount that Provision#host_config places at /home/agent/.local/share/opencode
# at runtime. Containers::Provision#seed_opencode_database! copies it from
# /opt into the tmpfs after the container starts.
USER agent
RUN mkdir -p /home/agent/.local/share/opencode \
    && timeout 10s opencode run "OK" > /dev/null 2>&1 || true
USER root
RUN mkdir -p /opt/opencode-seed \
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

# Install Aider CLI via agent-harness install contract.
# agent-harness owns the Aider install recipe, uv bootstrap, and version pin.
# The install command is extracted at build time by
# scripts/build-agent-image.sh / agent-image.yml — Paid no longer pins these versions.
ARG AIDER_INSTALL_COMMAND
RUN if [ -z "${AIDER_INSTALL_COMMAND}" ]; then \
        echo "ERROR: AIDER_INSTALL_COMMAND build-arg is required (sourced from agent-harness)" >&2; \
        exit 1; \
    fi \
    && eval "${AIDER_INSTALL_COMMAND}"

# Install git credential helper for proxy-based authentication.
# This allows git clone/push inside the container without exposing GitHub tokens.
COPY scripts/git-credential-paid /usr/local/bin/git-credential-paid
RUN chmod +x /usr/local/bin/git-credential-paid

# Configure git at system level so it works with ReadonlyRootfs.
# The credential helper fetches tokens from the secrets proxy on demand.
RUN git config --system init.defaultBranch main \
    && git config --system user.email "agent@paid.dev" \
    && git config --system user.name "Paid Agent" \
    && git config --system credential.helper /usr/local/bin/git-credential-paid

# Set up working directory
WORKDIR /workspace

# Switch to non-root user
USER agent

# Default command (overridden at runtime)
CMD ["bash"]
