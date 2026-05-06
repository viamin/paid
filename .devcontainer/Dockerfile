# Use the official Ruby devcontainer base image
ARG VARIANT=3.4-bookworm
FROM mcr.microsoft.com/devcontainers/ruby:${VARIANT}

# Switch to root for system package installation
USER root

# Install Node.js 22.x (needed for JS builds in docker-compose; redundant in devcontainer)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
  && apt-get install -y nodejs

# Install system dependencies
# Keep client tools on the same Postgres major as the pinned server image.
# Use the PGDG apt repository because Debian Bookworm does not ship client v16.
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
  && apt-get install -y ca-certificates curl postgresql-common \
  && install -d /usr/share/postgresql-common/pgdg \
  && curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc --fail https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  && . /etc/os-release \
  && printf 'Types: deb\nURIs: https://apt.postgresql.org/pub/repos/apt\nSuites: %s-pgdg\nArchitectures: %s\nComponents: main\nSigned-By: /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc\n' "$VERSION_CODENAME" "$(dpkg --print-architecture)" > /etc/apt/sources.list.d/pgdg.sources \
  && apt-get update -qq \
  && apt-get install -y build-essential cmake shellcheck tmux libpq-dev postgresql-client-16 \
  && rm -rf /var/lib/apt/lists/*

# Install chromium separately for better layer caching (updates more frequently)
RUN apt-get update -qq \
  && apt-get install -y chromium \
  && rm -rf /var/lib/apt/lists/*

# Install yarn
RUN corepack enable && corepack prepare yarn@1.22.22 --activate

# Install ast-grep for collector integration specs and local code analysis.
# Keep this inline instead of COPYing a repo script: the devcontainer image is
# often rebuilt from a minimal or noisy workspace context, and BuildKit has
# intermittently failed to resolve bin/install-ast-grep from that context.
ARG AST_GREP_VERSION=0.42.1
RUN set -eu; \
  arch="$(dpkg --print-architecture)"; \
  case "$arch" in \
    amd64) rust_triple="x86_64-unknown-linux-gnu"; checksum="5de8b87cba67fc8dc3e239d54b6484802ad745a7ae3de76be4fe89661dc52657" ;; \
    arm64) rust_triple="aarch64-unknown-linux-gnu"; checksum="3ba383839044cf9817929435f5ce0027f91d06931e8efb32d942e58d73d92be5" ;; \
    *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; \
  esac; \
  zipfile="app-${rust_triple}.zip"; \
  url="https://github.com/ast-grep/ast-grep/releases/download/${AST_GREP_VERSION}/${zipfile}"; \
  tmpdir="$(mktemp -d)"; \
  trap 'rm -rf "$tmpdir"' EXIT; \
  curl -fsSL -o "$tmpdir/$zipfile" "$url"; \
  echo "$checksum  $tmpdir/$zipfile" | sha256sum -c -; \
  unzip -j -o "$tmpdir/$zipfile" ast-grep -d "$tmpdir"; \
  install -m 0755 "$tmpdir/ast-grep" /usr/local/bin/ast-grep; \
  ln -sf /usr/local/bin/ast-grep /usr/local/bin/sg

# Install scc for collector integration specs and local code analysis.
ARG SCC_VERSION=3.7.0
RUN set -eu; \
  arch="$(dpkg --print-architecture)"; \
  case "$arch" in \
    amd64) scc_arch="x86_64"; checksum="3d9d65b00ca874c2b29151abe7e1480736f5229edc3ce8e4b2791460cdfabf5a" ;; \
    arm64) scc_arch="arm64"; checksum="dcb05c6e993bb2d8d2da4765ff018f2e752325dd205a41698929c55e4123575d" ;; \
    *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; \
  esac; \
  tarball="scc_Linux_${scc_arch}.tar.gz"; \
  url="https://github.com/boyter/scc/releases/download/v${SCC_VERSION}/${tarball}"; \
  tmpdir="$(mktemp -d)"; \
  trap 'rm -rf "$tmpdir"' EXIT; \
  curl -fsSL -o "$tmpdir/$tarball" "$url"; \
  echo "$checksum  $tmpdir/$tarball" | sha256sum -c -; \
  tar -xzf "$tmpdir/$tarball" -C /usr/local/bin scc; \
  chmod +x /usr/local/bin/scc

# Install overmind process manager (requires tmux, installed above)
RUN gem install overmind

# Install the required bundler version and fix permissions for vscode user
RUN gem install bundler:2.7.2 \
  && chmod -R g+w /usr/local/rvm/gems/default

# Ensure the docker group exists so the vscode user can access the Docker socket
RUN groupadd -f docker && usermod -aG docker vscode

USER vscode

# Pre-create ~/.local tree so bind mounts don't leave root-owned parents
# (Docker creates missing mount-point parents as root, blocking vscode writes)
RUN mkdir -p /home/vscode/.local/bin \
             /home/vscode/.local/state \
             /home/vscode/.local/share

# Add rbenv to PATH
ENV PATH="/home/vscode/.rbenv/shims:/home/vscode/.rbenv/bin:${PATH}"

# Ensure binding is always 0.0.0.0
# Binds the server to all IP addresses of the container, so it can be accessed from outside the container.
ENV BINDING="0.0.0.0"
