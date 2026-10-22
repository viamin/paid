---
parent: PAID
prefix: TEST-SUITE
---

# Design: Test Suite Performance

## Purpose

Paid's non-system CI suite runs over 25,000 examples serially and takes about
43 minutes of test execution. The slowest individual examples account for only
a small fraction of that total. Reduce feedback latency while retaining every
existing check, example, isolation boundary, and the 80% whole-suite coverage
floor. Keep local `bin/rspec` and separate system/performance checks available.

## Execution

Partition all non-system, non-performance spec files into four deterministic,
disjoint groups. Assign largest source files first to the least-loaded group,
using file bytes as a cheap structural estimate, not a correctness judgment or
promise of equal runtime. Each CI job has its own PostgreSQL/Qdrant services,
workspace and temporary files. Files and examples are never split across jobs.
Random ordering within a shard continues to expose order dependencies.

Each shard uses the existing RSpec runner, records a unique coverage command
name, and uploads raw coverage and JSON example timings even on failure. Disable
per-shard HTML formatting and partial-suite coverage thresholds only in shard
mode. A stable final `test` job requires every shard to succeed, verifies all
expected distinct coverage reports exist, then collates them with the original
Rails filters and enforces the existing 80% minimum. Missing reports, failing
shards, or insufficient combined coverage fail the final check. Separate query
performance specs run once, and the system-test workflow remains unchanged.

## Individual test costs

Certificate behavior specs use the existing explicit test key-size parameter
while retaining real key generation, certificate signing, chain validation and
encrypted storage. Production key sizes remain unchanged. CLI specs inherit
Rails database configuration instead of demanding a DATABASE_URL or imposing
agent-container defaults. Keep cold-process boot and CLI checks where process
startup is part of the contract; do not replace them with application mocks.
Use the current Ruby directly when the target already loads Bundler, avoiding a
redundant `bundle exec ruby` wrapper. Suppress child-only profiler diagnostics
that would corrupt boot/coverage probe output while profiling the parent suite.

## Measurement and profiling

JSON timings make each shard's examples and durations inspectable. The existing
opt-in test-prof workflow must allow a full suite to finish within its timeout;
profiling does not relax normal CI requirements. Compare before/after focused
examples and actual CI wall time. Four jobs reduce latency at the cost of extra
setup runner minutes; they do not claim a fourfold reduction in total CPU work.

## Open decisions

Use observed timing artifacts to refine balancing if source-size estimates cause
material skew. Broader shared-setup adoption requires direct profiles and isolation
evidence; do not globally bypass callbacks, tenant checks or validation.

## Reducing repeated work

CLI listing, help and invalid-argument checks run before Rails boot. Provider
metadata lives in one Rails-independent catalog shared with Runner; actual smoke
execution still delegates to the existing RSpec entry point, which boots Rails.
Apple preflight and project lookup retain Rails and database checks.

Reuse stable persisted setup graphs in profiled hotspot groups with the installed
test-prof `let_it_be` recipe and `refind: true`. Normal factories create the graph
inside a group transaction; each example refetches fresh model instances and
rolls its mutations back. Provisioning shares setup only in its provisioning
scenarios. Other cases retain lazy per-example setup. Preserve the existing system
access context during group initialization. Keep issues, agent runs and
scenario-specific records/settings per example, including creation overrides
under active-run uniqueness constraints. Preserve association identity within
each example. Do not share mutable model objects or disable callbacks/validations.

Prompt seed specs load the actual application default seed script once in a
test-prof group transaction. Per-example transactions isolate mutations; a
repeated synchronization check verifies stable prompt/version identities. The
PR scanner shares only its baseline project graph with its existing settings,
using fresh records per example instead of replaying a FixtureKit SQL snapshot.
Keep scenario-specific issues, runs, projects and configuration changes local
to each example. FactoryBot remains the record builder; no global seed dataset
or new data framework is required for these optimizations.

Focused Apple live-validation examples inject a subset of the actual scenario
matrix through the existing suite port, retaining network, capacity and reporting
evidence scaffolding. Keep a full default-suite integration
example to verify all scenario IDs and repeat counts. Capacity checks retain
the functional work that collects their samples; recovery checks retain their
real persistence and cleanup choreography.

Shell availability checks need only persisted authorization and clone-manifest
metadata. Create filesystem workspaces only for execution and path-validation
checks, with cleanup that never evaluates unused lazy setup.

HTTP retry tests record delays by replacing the external Faraday retry
middleware's timer. Keep real middleware, HTTP response sequences, retry counts,
backoff configuration and exhaustion behavior. Production timing is unchanged.

Profile model, queue and request factory cascades before selecting further shared
graphs. Reuse stable request account/user/credential/project configuration only
where overrides preserve its dependencies. Keep scenario records and roles per
example, and verify graph mutation isolation. Do not disable callbacks or alter
global factory defaults to reduce counts.

Queue host-saturation setup reuses one project per generated load batch. Host
occupancy retains a distinct active run and issue for every requested slot;
other accounts and independently constructed batches remain separate.
