---
parent: PAID
prefix: TEST-SUITE
---

# EARS Specs: Test Suite Performance

- [x] **TEST-SUITE-001** — When CI partitions the non-system RSpec suite, it SHALL assign every eligible spec file to exactly one deterministic shard and SHALL exclude system and performance specs from that partition.
- [x] **TEST-SUITE-002** — When a shard count or index is invalid, the shard runner SHALL fail before executing tests; an empty selected shard SHALL fail rather than silently pass.
- [x] **TEST-SUITE-003** — When CI runs test shards, each shard SHALL execute with isolated database/services/workspace state and SHALL preserve existing RSpec example execution and randomization.
- [x] **TEST-SUITE-004** — When CI checks combined coverage, it SHALL require one distinct non-empty report for every expected shard and SHALL reject missing, duplicate, malformed or unexpected reports.
- [x] **TEST-SUITE-005** — When CI collates complete shard reports, the final test check SHALL apply the existing Rails coverage filters and SHALL fail below 80% combined coverage; individually incomplete coverage SHALL not be mistaken for incomplete aggregate coverage.
- [x] **TEST-SUITE-006** — When any CI test shard fails or is cancelled, the stable final test check SHALL fail; system tests and the query-performance slice SHALL retain their existing execution coverage.
- [x] **TEST-SUITE-007** — When certificate behavior specs generate keys, they SHALL use the existing explicit smaller test-key option without changing production defaults or omitting signing, chain validation or encryption assertions.
- [x] **TEST-SUITE-008** — When Apple worker CLI specs run without DATABASE_URL, they SHALL inherit the configured Rails test connection rather than fail solely because a URL is absent.
- [x] **TEST-SUITE-009** — When CI profiles the test suite, it SHALL retain per-example timing artifacts and SHALL give the opt-in full-suite profiler a timeout sufficient for the known serial suite duration.

- [x] **TEST-SUITE-010** — When CLI commands only list providers, show usage, or reject invalid smoke arguments, they SHALL finish without booting Rails, preserve documented output and exit codes, and use the same provider catalog as application runner configuration.
- [x] **TEST-SUITE-011** — When hotspot specs reuse a persisted fixture graph, each example SHALL receive fresh model instances and transactional isolation; mutations SHALL NOT leak between examples and normal callbacks, validations and tenant constraints SHALL remain enabled.
- [x] **TEST-SUITE-012** — When prompt seed specs run, they SHALL load the actual default seed script once per group, isolate per-example mutations, and verify repeated synchronization preserves prompt and version identities.
- [x] **TEST-SUITE-013** — When PR scanner specs reuse their baseline project, they SHALL create its graph once per group with the existing scanner settings, refetch model instances per example, and roll back scenario-specific changes without SQL snapshot replay.
- [x] **TEST-SUITE-014** — When Apple live-validation specs exercise a focused scenario, they SHALL limit provisioning, recovery and diagnostics work to the scenarios under test and retain a full default-matrix integration check, including repeat counts and recovery convergence.
- [x] **TEST-SUITE-015** — When shell-tool availability specs run, they SHALL use manifest metadata without initializing a filesystem workspace; execution specs SHALL retain real shell execution, authorization and path-boundary checks.
- [x] **TEST-SUITE-016** — When HTTP retry specs suppress elapsed waiting, they SHALL replace only the external middleware timer, retaining actual attempts, configured backoff, retry exhaustion and mutation non-retry checks.
- [x] **TEST-SUITE-017** — When factory profiling identifies repeated stable setup, hotspot specs SHALL reuse only configuration graphs with fresh instances per example and transactional rollback; scenario runs, issues and authorization changes SHALL remain isolated, including distinct runs and issues for each simulated host slot.
