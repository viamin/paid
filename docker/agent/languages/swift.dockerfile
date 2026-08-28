# syntax=docker/dockerfile:1
# Swift language layer for the Paid agent image (RDR-046 Phase 3 / #3613).
#
# Composed by Containers::ComboImageBuilder (and scripts/build-agent-image.sh)
# with BASE_IMAGE pointed at the base agent image — or at a previously built
# layer when a combo needs more than one extended runtime. Installs the
# official Swift toolchain for Linux (Swift Package Manager projects only —
# iOS/Xcode-only targets cannot compile on Linux per RDR-046).

ARG BASE_IMAGE=paid-agent:latest
FROM ${BASE_IMAGE}

# Checksums computed from the official swift.org release artifacts:
# https://download.swift.org/swift-6.3.3-release/ubuntu2404[-aarch64]/swift-6.3.3-RELEASE/
ARG SWIFT_VERSION=6.3.3
ARG UBUNTU_PLATFORM=ubuntu24.04
ARG SWIFT_SHA256_AMD64=da8272a5fddccd65b1529ed0e52e04526e2eadd4237d58d6220efeb973c6cd19
ARG SWIFT_SHA256_ARM64=47126395429653fa768d370655876ec1b68f6a95c7884f5e4f179700141c9b7f

# Runtime dependencies per swift.org's Ubuntu 24.04 install guidance. The base
# image already provides git/curl/unzip/ca-certificates.
RUN apt-get update && apt-get install -y --no-install-recommends \
        binutils \
        gnupg2 \
        libc6-dev \
        libcurl4-openssl-dev \
        libedit2 \
        libgcc-13-dev \
        libpython3.12t64 \
        libsqlite3-0 \
        libstdc++-13-dev \
        libxml2-dev \
        libz3-dev \
        pkg-config \
        tzdata \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

RUN DEB_ARCH="$(dpkg --print-architecture)" \
    && case "${DEB_ARCH}" in \
        amd64) SWIFT_DIR="ubuntu2404"; SWIFT_SUFFIX=""; SWIFT_SHA256="${SWIFT_SHA256_AMD64}" ;; \
        arm64) SWIFT_DIR="ubuntu2404-aarch64"; SWIFT_SUFFIX="-aarch64"; SWIFT_SHA256="${SWIFT_SHA256_ARM64}" ;; \
        *) echo "Unsupported architecture for Swift layer: ${DEB_ARCH}" >&2; exit 1 ;; \
    esac \
    && RELEASE="swift-${SWIFT_VERSION}-RELEASE" \
    && TARBALL="${RELEASE}-${UBUNTU_PLATFORM}${SWIFT_SUFFIX}.tar.gz" \
    && curl -fsSL \
        "https://download.swift.org/swift-${SWIFT_VERSION}-release/${SWIFT_DIR}/${RELEASE}/${TARBALL}" \
        -o "/tmp/${TARBALL}" \
    && echo "${SWIFT_SHA256}  /tmp/${TARBALL}" | sha256sum -c - \
    && mkdir -p /usr/share/swift \
    && tar -C /usr/share/swift -xzf "/tmp/${TARBALL}" --strip-components=1 \
    && rm "/tmp/${TARBALL}"

ENV PATH=/usr/share/swift/usr/bin:${PATH}

RUN swift --version 2>/dev/null | head -n 1
