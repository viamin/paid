# syntax=docker/dockerfile:1
# Go language layer for the Paid agent image (RDR-046 Phase 3 / #3613).
#
# Composed by Containers::ComboImageBuilder (and scripts/build-agent-image.sh)
# with BASE_IMAGE pointed at the base agent image — or at a previously built
# layer when a combo needs more than one extended runtime. Installs the pinned
# official Go toolchain tarball with per-architecture checksum verification.

ARG BASE_IMAGE=paid-agent:latest
FROM ${BASE_IMAGE}

# Checksums from the official release manifest (https://go.dev/dl/?mode=json).
ARG GO_VERSION=1.27.0
ARG GO_SHA256_AMD64=675c26c449cbb18fc24b74650de1eabbae6e16f64326fd85a283fb3b58280685
ARG GO_SHA256_ARM64=51798d2c42d0e1c6ed7fd9f48728b4193abac9e8aad6dbac2fe96a81f5909bda

RUN DEB_ARCH="$(dpkg --print-architecture)" \
    && case "${DEB_ARCH}" in \
        amd64) GO_SHA256="${GO_SHA256_AMD64}" ;; \
        arm64) GO_SHA256="${GO_SHA256_ARM64}" ;; \
        *) echo "Unsupported architecture for Go layer: ${DEB_ARCH}" >&2; exit 1 ;; \
    esac \
    && TARBALL="go${GO_VERSION}.linux-${DEB_ARCH}.tar.gz" \
    && curl -fsSLO "https://go.dev/dl/${TARBALL}" \
    && echo "${GO_SHA256}  ${TARBALL}" | sha256sum -c - \
    && tar -C /usr/local -xzf "${TARBALL}" \
    && rm "${TARBALL}"

ENV GOROOT=/usr/local/go
ENV GOPATH=/home/agent/go
# Module/build caches default under GOCACHE=$HOME/.cache, which is writable in
# agent containers; GOPATH stays in the writable agent home too because the
# image root is mounted read-only at run time.
ENV PATH=/usr/local/go/bin:/home/agent/go/bin:${PATH}

RUN go version
