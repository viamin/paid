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

# Install Node.js 22.x (for Claude Code and other JS-based agents)
# Note: Using NodeSource setup script is standard practice for Node.js installation
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install Ruby and Python (for Rails projects and various agents/tools)
# Combined into single RUN to reduce Docker layers
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
RUN git config --global init.defaultBranch main \
    && git config --global user.email "agent@paid.dev" \
    && git config --global user.name "Paid Agent"

# Default command (overridden at runtime)
CMD ["bash"]
