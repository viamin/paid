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
# Using direct download with checksum verification for supply-chain security
# Keep version in sync with .node-version
RUN NODE_VERSION=22.12.0 \
    && DEB_ARCH="$(dpkg --print-architecture)" \
    && case "$DEB_ARCH" in \
        amd64) NODE_ARCH="x64" ;; \
        arm64) NODE_ARCH="arm64" ;; \
        *) echo "Unsupported architecture: $DEB_ARCH" >&2; exit 1 ;; \
    esac \
    && curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.gz" \
    && curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" \
    && grep "node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.gz" SHASUMS256.txt | sha256sum -c - \
    && tar -xzf "node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.gz" -C /usr/local --strip-components=1 \
    && rm "node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.gz" SHASUMS256.txt

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
RUN npm install -g @anthropic/claude-code

# Create non-root user for security
RUN useradd -m -s /bin/bash agent \
    && mkdir -p /workspace /home/agent/.config \
    && chown -R agent:agent /workspace /home/agent

# Set up working directory
WORKDIR /workspace

# Switch to non-root user
USER agent

# Configure git for the agent user
# Note: These are default placeholders; actual user info is set at runtime for commits
RUN git config --global init.defaultBranch main \
    && git config --global user.email "agent@localhost" \
    && git config --global user.name "Paid Agent"

# Default command (overridden at runtime)
CMD ["bash"]
