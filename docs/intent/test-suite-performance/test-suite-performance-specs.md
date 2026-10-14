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
