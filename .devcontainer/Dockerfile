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
  && apt-get install -y build-essential cmake python3-pip shellcheck tmux libpq-dev postgresql-client-16=16.14-1.pgdg12+1 \
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

# Install rathole for local preview tunnel development.
ARG RATHOLE_VERSION=0.5.0
RUN set -eu; \
  arch="$(dpkg --print-architecture)"; \
  case "$arch" in \
    amd64) asset="rathole-x86_64-unknown-linux-gnu.zip"; checksum="3e7d0d0f365120cd3cd351d147d1a12ee960c8068b464d4dd533a3821873b80e" ;; \
    arm64) asset="rathole-aarch64-unknown-linux-musl.zip"; checksum="fa4a6fc63d86f8f1faa7c103a845e4715ce79a048455c0eec897b27237576564" ;; \
    *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; \
  esac; \
  tmpdir="$(mktemp -d)"; \
  trap 'rm -rf "$tmpdir"' EXIT; \
  curl -fsSL -o "$tmpdir/$asset" "https://github.com/rathole-org/rathole/releases/download/v${RATHOLE_VERSION}/${asset}"; \
  echo "$checksum  $tmpdir/$asset" | sha256sum -c -; \
  unzip -j -o "$tmpdir/$asset" rathole -d "$tmpdir"; \
  install -m 0755 "$tmpdir/rathole" /usr/local/bin/rathole

# Install rtk (Rust Token Killer) for compressed AI agent shell output.
# rtk intercepts shell commands from AI agents and compresses the output 60-90%,
# reducing context window consumption.
# https://github.com/rtk-ai/rtk/releases
ARG RTK_VERSION=0.43.0
RUN set -eu; \
  arch="$(dpkg --print-architecture)"; \
  case "$arch" in \
    amd64) asset="rtk-x86_64-unknown-linux-musl.tar.gz"; checksum="ff8a1e7766496e175291a85aeca1dc97c9ff6df33e51e5893d1fbc78fea2a609" ;; \
    arm64) asset="rtk-aarch64-unknown-linux-gnu.tar.gz"; checksum="5519f7ca12e5c143a609f0d28a0a77b97413a8dce31c2681f1a41c24519a8731" ;; \
    *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; \
  esac; \
  tmpdir="$(mktemp -d)"; \
  trap 'rm -rf "$tmpdir"' EXIT; \
  curl -fsSL -o "$tmpdir/$asset" "https://github.com/rtk-ai/rtk/releases/download/v${RTK_VERSION}/${asset}"; \
  echo "$checksum  $tmpdir/$asset" | sha256sum -c -; \
  tar -xzf "$tmpdir/$asset" -C "$tmpdir"; \
  install -m 0755 "$tmpdir/rtk" /usr/local/bin/rtk

# Install CodeGraph for local-first code intelligence via MCP.
# Builds a code knowledge graph that agents query instead of grepping/reading
# files one at a time, reducing tool calls and tokens.
# https://github.com/colbymchenry/codegraph
ARG CODEGRAPH_VERSION=1.5.0
RUN npm install -g @colbymchenry/codegraph@${CODEGRAPH_VERSION} --ignore-scripts

# Install overmind process manager (requires tmux, installed above)
RUN gem install overmind

# Install the Bundler version pinned in Gemfile.lock and fix permissions for
# the vscode user. COPYing only the lockfile keeps rebuild scope narrow.
COPY Gemfile.lock /tmp/paid-devcontainer/Gemfile.lock
RUN BUNDLER_VERSION="$(awk '/^BUNDLED WITH$/{getline; gsub(/^ +/, "", $0); print $0}' /tmp/paid-devcontainer/Gemfile.lock)" \
  && test -n "${BUNDLER_VERSION}" \
  && gem install "bundler:${BUNDLER_VERSION}" \
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
