#!/bin/sh
# Exact tested child body; use documented outer timeout and assigned job limits.
set -eu; mkdir -p /tmp/home; timeout --signal=TERM --kill-after=5 900s cargo check --locked --offline --package temporalio-sdk-core; cd /workspace; sha256sum --check --status source.before.sha; echo 'SOURCE FILES UNCHANGED'
