#!/bin/sh
# Exact tested child body; use documented outer timeout and assigned job limits.
set -eu; mkdir -p /tmp/home /workspace/cargo; uname -m; cargo --version; rustc --version; /workspace/tools/protoc/bin/protoc --version; printf '47aba453a6f46d71b5deba2d09e1e6b9ef036cc5ba7263562793205e142bc9aa  Cargo.lock\n' | sha256sum -c -; cd /workspace; find ruby -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > source.before.sha; cd /workspace/ruby/temporalio; timeout --signal=TERM --kill-after=5 300s cargo fetch --locked
