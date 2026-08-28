# syntax=docker/dockerfile:1
# Rust language layer for the Paid agent image (RDR-046 Phase 3 / #3613).
#
# Composed by Containers::ComboImageBuilder (and scripts/build-agent-image.sh)
# with BASE_IMAGE pointed at the base agent image — or at a previously built
# layer when a combo needs more than one extended runtime. Installs a pinned
# rustup release (checksum-verified, per architecture) and a pinned stable
# toolchain.
#
# Layout: the toolchain and rustup shims live under /usr/local (present in the
# image regardless of run-time volume mounts), while CARGO_HOME points into
# the writable agent home so registry/target caches survive the read-only root
# filesystem used by agent containers.

ARG BASE_IMAGE=paid-agent:latest
FROM ${BASE_IMAGE}

# Checksums from the official rustup release manifest
# (https://static.rust-lang.org/rustup/archive/<version>/<target>/rustup-init).
ARG RUSTUP_VERSION=1.29.0
ARG RUST_TOOLCHAIN=1.98.0
ARG RUSTUP_SHA256_AMD64=4acc9acc76d5079515b46346a485974457b5a79893cfb01112423c89aeb5aa10
ARG RUSTUP_SHA256_ARM64=9732d6c5e2a098d3521fca8145d826ae0aaa067ef2385ead08e6feac88fa5792

ENV RUSTUP_HOME=/usr/local/rustup
ENV CARGO_HOME=/home/agent/.cargo
ENV PATH=/usr/local/cargo/bin:${PATH}

RUN DEB_ARCH="$(dpkg --print-architecture)" \
    && case "${DEB_ARCH}" in \
        amd64) RUSTUP_TARGET="x86_64-unknown-linux-gnu"; RUSTUP_SHA256="${RUSTUP_SHA256_AMD64}" ;; \
        arm64) RUSTUP_TARGET="aarch64-unknown-linux-gnu"; RUSTUP_SHA256="${RUSTUP_SHA256_ARM64}" ;; \
        *) echo "Unsupported architecture for Rust layer: ${DEB_ARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSLO \
        "https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${RUSTUP_TARGET}/rustup-init" \
    && echo "${RUSTUP_SHA256}  rustup-init" | sha256sum -c - \
    && chmod +x rustup-init \
    && CARGO_HOME=/usr/local/cargo ./rustup-init -y \
        --profile minimal \
        --default-toolchain "${RUST_TOOLCHAIN}" \
        --no-modify-path \
    && rm rustup-init \
    && /usr/local/cargo/bin/rustc --version \
    && /usr/local/cargo/bin/cargo --version
