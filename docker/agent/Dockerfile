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

# Install Ruby and Python (for Rails projects and various agents/tools)
# Note: Using Ubuntu package manager versions (Ruby 3.2.x, Python 3.12.x)
# Exact versions depend on Ubuntu 24.04 package availability
RUN apt-get update && apt-get install -y --no-install-recommends \
    ruby-full \
    ruby-bundler \
    python3 \
    python3-pip \
    python3-venv \
    && rm -rf /var/lib/apt/lists/*

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
