# syntax=docker/dockerfile:1
# Elixir language layer for the Paid agent image (RDR-046 Phase 3 / #3613).
#
# Composed by Containers::ComboImageBuilder (and scripts/build-agent-image.sh)
# with BASE_IMAGE pointed at the base agent image — or at a previously built
# layer when a combo needs more than one extended runtime. Installs Erlang/OTP
# from pre-compiled Ubuntu packages (never compiled from source, per RDR-046)
# and a pinned pre-compiled Elixir build that matches that OTP major.

ARG BASE_IMAGE=paid-agent:latest
FROM ${BASE_IMAGE}

# Elixir pre-compiled release assets:
# https://github.com/elixir-lang/elixir/releases/download/v1.18.4/elixir-otp-25.zip.sha256sum
# 1.18.4 is the newest Elixir line that still publishes OTP-25 builds; OTP 25
# is what Ubuntu 24.04 (noble) packages (erlang 1:25.3.2.8).
ARG ELIXIR_VERSION=1.18.4
ARG ELIXIR_OTP_MAJOR=25
ARG ELIXIR_SHA256=04ecc784c59692ce15511fbba54638d947f0566f5baf69c6542d4bf2ea89cd1a

RUN apt-get update && apt-get install -y --no-install-recommends \
        erlang-base \
        erlang-dev \
        erlang-asn1 \
        erlang-crypto \
        erlang-eunit \
        erlang-inets \
        erlang-mnesia \
        erlang-os-mon \
        erlang-parsetools \
        erlang-public-key \
        erlang-runtime-tools \
        erlang-ssh \
        erlang-ssl \
        erlang-syntax-tools \
        erlang-tools \
        erlang-xmerl \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL \
        "https://github.com/elixir-lang/elixir/releases/download/v${ELIXIR_VERSION}/elixir-otp-${ELIXIR_OTP_MAJOR}.zip" \
        -o /tmp/elixir.zip \
    && echo "${ELIXIR_SHA256}  /tmp/elixir.zip" | sha256sum -c - \
    && unzip -q /tmp/elixir.zip -d /usr/local/lib/elixir \
    && rm /tmp/elixir.zip \
    && for binary in elixir elixirc iex mix; do \
        ln -sf "/usr/local/lib/elixir/bin/${binary}" "/usr/local/bin/${binary}"; \
    done \
    && elixir --version

# Mix writes its archives (Hex, Rebar) to MIX_HOME; keep that in the writable
# agent home rather than the read-only image root so `mix local.hex` works at
# run time.
ENV MIX_HOME=/home/agent/.mix
