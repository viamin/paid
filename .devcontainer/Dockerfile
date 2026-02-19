# Use the official Ruby devcontainer base image
ARG VARIANT=3.4-bullseye
FROM mcr.microsoft.com/devcontainers/ruby:${VARIANT}

# Switch to root for system package installation
USER root

# Install Node.js 22.x (needed for JS builds in docker-compose; redundant in devcontainer)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
  && apt-get install -y nodejs

# Install system dependencies
RUN apt-get update && apt-get install -y \
  build-essential \
  cmake \
  chromium \
  tmux \
  libpq-dev \
  && rm -rf /var/lib/apt/lists/*

# Install yarn
RUN corepack enable && corepack prepare yarn@1.22.22 --activate

# Install overmind process manager (requires tmux, installed above)
RUN gem install overmind

# Install the required bundler version and fix permissions for vscode user
RUN gem install bundler:2.7.2 \
  && chmod -R g+w /usr/local/rvm/gems/default

# Ensure the docker group exists so the vscode user can access the Docker socket
RUN groupadd -f docker && usermod -aG docker vscode

USER vscode

# Add rbenv to PATH
ENV PATH="/home/vscode/.rbenv/shims:/home/vscode/.rbenv/bin:${PATH}"

# Ensure binding is always 0.0.0.0
# Binds the server to all IP addresses of the container, so it can be accessed from outside the container.
ENV BINDING="0.0.0.0"
