# EARS Specs: Learned Orchestration

> Testable claims for data-backed orchestration strategy selection.
> Status markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.

- [x] **LEARNED-ORCH-001** — When selecting an orchestration strategy, the
  system SHALL prefer the most specific active match across project, account,
  and global scopes and SHALL return a structured fallback result with empty
  content when no learned strategy matches.
  *Code:* `Strategies::Select`.

- [x] **LEARNED-ORCH-002** — When activating a later active strategy version,
  the system SHALL require explicit promotion metadata so learned strategy
  promotion remains human reviewed.
  *Code:* `StrategyVersion`.
