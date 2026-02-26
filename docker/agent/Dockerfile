# syntax=docker/dockerfile:1
# Agent container image for running AI coding assistants (Claude Code, etc.)
# This container provides an isolated environment for AI agents to execute code.

FROM ubuntu:24.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install base dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    curl \
    git \
    jq \
    unzip \
    wget \
    ca-certificates \
    gnupg \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 22.12.0 (pinned version for reproducible builds)
# Using direct download with pinned checksum verification for supply-chain security
# Checksums from official release: https://nodejs.org/download/release/v22.12.0/SHASUMS256.txt
# Keep version in sync with .tool-versions
RUN NODE_VERSION=22.12.0 \
    && DEB_ARCH="$(dpkg --print-architecture)" \
    && case "$DEB_ARCH" in \
        amd64) NODE_ARCH="x64"; EXPECTED_CHECKSUM="e05a4d65232ae2b27b3d77da2e368522fb46b923335b8e0d5f77624c32484044" ;; \
        arm64) NODE_ARCH="arm64"; EXPECTED_CHECKSUM="9e7905fdee722f9650a03ae644b51c4c6effd3b98ac93c588700072ab35c9ddb" ;; \
        *) echo "Unsupported architecture: $DEB_ARCH" >&2; exit 1 ;; \
    esac \
    && TARBALL="node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.gz" \
    && curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/${TARBALL}" \
    && echo "${EXPECTED_CHECKSUM}  ${TARBALL}" | sha256sum -c - \
    && tar -xzf "${TARBALL}" -C /usr/local --strip-components=1 \
    && rm "${TARBALL}"

# Install Ruby build dependencies, runtime deps, Python, PostgreSQL client libs, and ShellCheck
RUN apt-get update && apt-get install -y --no-install-recommends \
    autoconf \
    bison \
    libssl-dev \
    libreadline-dev \
    zlib1g-dev \
    libyaml-dev \
    libffi-dev \
    libgdbm-dev \
    libpq-dev \
    rustc \
    shellcheck \
    python3 \
    python3-pip \
    python3-venv \
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

# Remove build-only dependencies to reduce image size and attack surface.
# Keep runtime libs (libssl, libreadline, zlib, libyaml, libffi, libgdbm, libpq)
# which are pulled in as transitive deps of the -dev packages.
RUN apt-get update && apt-get purge -y --auto-remove \
    autoconf \
    bison \
    rustc \
    && rm -rf /var/lib/apt/lists/*

# Install Bundler (pinned to match Gemfile.lock)
RUN gem install bundler:2.7.2

# Install Yarn via corepack (pinned to match package.json)
RUN corepack enable && corepack prepare yarn@1.22.22 --activate

# Install ast-grep (AST-based code search/lint)
# https://github.com/ast-grep/ast-grep/releases
RUN AST_GREP_VERSION=0.41.0 \
    && DEB_ARCH="$(dpkg --print-architecture)" \
    && case "$DEB_ARCH" in \
        amd64) RUST_TRIPLE="x86_64-unknown-linux-gnu"; EXPECTED_CHECKSUM="e71afdcbb2e79f7710a56d2f89662bdd0a6e9d639c4abecd5d5f129d80a38bac" ;; \
        arm64) RUST_TRIPLE="aarch64-unknown-linux-gnu"; EXPECTED_CHECKSUM="6f089d014d5fda8fed2e63e5095acf8ebec4c4cd2e721bd663f2284ace42b623" ;; \
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
RUN SCC_VERSION=3.6.0 \
    && DEB_ARCH="$(dpkg --print-architecture)" \
    && case "$DEB_ARCH" in \
        amd64) SCC_ARCH="x86_64"; EXPECTED_CHECKSUM="da923e0b94c5ce818088ba2e3d1667cdb064b3c684592e3c774c7f97b63194f6" ;; \
        arm64) SCC_ARCH="arm64"; EXPECTED_CHECKSUM="87fd3f5d4c393c6b665d23bf9b601753b2f6f8a953e6f265d5ea1498195d082f" ;; \
        *) echo "Unsupported architecture: $DEB_ARCH" >&2; exit 1 ;; \
    esac \
    && TARBALL="scc_Linux_${SCC_ARCH}.tar.gz" \
    && curl -fsSL -o "${TARBALL}" "https://github.com/boyter/scc/releases/download/v${SCC_VERSION}/${TARBALL}" \
    && echo "${EXPECTED_CHECKSUM}  ${TARBALL}" | sha256sum -c - \
    && tar -xzf "${TARBALL}" -C /usr/local/bin scc \
    && chmod +x /usr/local/bin/scc \
    && rm "${TARBALL}"

# Install Claude Code CLI (primary agent for MVP)
# The installer places the binary under /root/.local/ which is inaccessible to the
# non-root "agent" user. Copy the resolved binary to a system-wide path instead.
RUN curl -fsSL https://claude.ai/install.sh | bash \
    && cp -L /root/.local/bin/claude /usr/local/bin/claude \
    && chmod +x /usr/local/bin/claude

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

# Create non-root user for security
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /workspace /home/agent/.config \
    && chown -R agent:agent /workspace /home/agent

# Set up working directory
WORKDIR /workspace

# Switch to non-root user
USER agent

# Default command (overridden at runtime)
CMD ["bash"]
