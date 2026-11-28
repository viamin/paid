---
parent: PAID
prefix: MAIN-CI
---

# Main CI recovery specifications

- [x] **MAIN-CI-001** — Authenticated completed workflow/check events SHALL wake current-default-branch reconciliation; missed events SHALL be reconciled by polling, with exact repository, workflow, SHA and episode binding.
- [x] **MAIN-CI-002** — A verified required main failure SHALL retain redacted failure evidence and block ordinary automatic merges; missing or incomplete evidence SHALL never establish a healthy baseline.
- [x] **MAIN-CI-003** — Recovery SHALL deduplicate dispatch and bounded infrastructure retries, preserve ordinary trust, budgets and authorization, and use a known-good executor with isolated candidate execution.
- [x] **MAIN-CI-004** — A recovery prompt SHALL require attribution from the last verified green revision, tested safe reverts or fix-forward work, failing examples and normal checks, without authorizing resets, force pushes or database rollback.
- [x] **MAIN-CI-005** — The recovery merge lane SHALL admit only the recorded episode's repair PR at its verified head and SHALL retain ordinary review and merge gates, including final credential fallback checks.
- [x] **MAIN-CI-006** — Only complete successful required verification of current repaired main SHALL clear the blocker and refresh the trusted baseline; stale or out-of-order events SHALL not release or recreate newer state.
- [x] **MAIN-CI-007** — Recovery state SHALL remain tenant-isolated and record observation, dispatch and verification times; disabled projects SHALL preserve existing behavior.
