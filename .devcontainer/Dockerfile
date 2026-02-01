# Use the official Ruby devcontainer base image
ARG VARIANT=3.4-bullseye
FROM mcr.microsoft.com/devcontainers/ruby:${VARIANT}

# Switch to root for system package installation
USER root

# Install system dependencies
RUN apt-get update && apt-get install -y \
  build-essential \
  cmake \
  tmux \
  && rm -rf /var/lib/apt/lists/*

USER vscode

# Add rbenv to PATH
ENV PATH="/home/vscode/.rbenv/shims:/home/vscode/.rbenv/bin:${PATH}"

# Ensure binding is always 0.0.0.0
# Binds the server to all IP addresses of the container, so it can be accessed from outside the container.
ENV BINDING="0.0.0.0"
