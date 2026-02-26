# Use the official Ruby devcontainer base image
ARG VARIANT=3.4-bookworm
FROM mcr.microsoft.com/devcontainers/ruby:${VARIANT}

# Switch to root for system package installation
USER root

# Install Node.js 22.x (needed for JS builds in docker-compose; redundant in devcontainer)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
  && apt-get install -y nodejs

# Install system dependencies
# Use CloudFront mirror to avoid Fastly CDN connection drops in OrbStack
RUN set -e; \
  sources_modified=0; \
  if ls /etc/apt/sources.list.d/*.sources >/dev/null 2>&1; then \
    sed -i 's|http://deb.debian.org|http://cloudfront.debian.net|g' /etc/apt/sources.list.d/*.sources && sources_modified=1; \
  fi; \
  if [ -f /etc/apt/sources.list ]; then \
    sed -i 's|http://deb.debian.org|http://cloudfront.debian.net|g' /etc/apt/sources.list && sources_modified=1; \
  fi; \
  if [ "$sources_modified" -eq 0 ]; then \
    echo "Info: no APT sources were updated to use the CloudFront mirror; this can be normal for some base images." >&2; \
  fi; \
  echo 'Acquire::Retries "3";' > /etc/apt/apt.conf.d/80-retries \
  && apt-get update -qq \
  && apt-get install -y build-essential cmake shellcheck tmux libpq-dev \
  && rm -rf /var/lib/apt/lists/*

# Install chromium separately for better layer caching (updates more frequently)
RUN apt-get update -qq \
  && apt-get install -y chromium \
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
