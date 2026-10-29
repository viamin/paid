# EARS Specs: Operational Supervisor

> Proposed claims for RDR-063. `[ ]` denotes active, held implementation work.

- [ ] **OPERATIONAL-SUPERVISOR-001** — When building a supervisor snapshot, the system SHALL include only the RDR-063 typed allowlist and SHALL exclude authored content, repository content, logs, prompts, raw errors, credentials, secrets, and raw provider responses.
- [ ] **OPERATIONAL-SUPERVISOR-002** — When a snapshot contains a metric, the system SHALL retain its window, denominator, inclusion rule, and unavailable state, and SHALL bound deterministic top-N selection without encoding a semantic quality judgment.
- [ ] **OPERATIONAL-SUPERVISOR-003** — When analyzing a snapshot, the system SHALL call only `agent_harness` and SHALL accept only a strict structured response whose known targets are members of that snapshot.
- [ ] **OPERATIONAL-SUPERVISOR-004** — If analysis output is malformed, unknown, unauthorized, or fails current-state validation, the system SHALL fail closed with no operational mutation and record only sanitized health evidence.
- [ ] **OPERATIONAL-SUPERVISOR-005** — When a validated finding recurs, the system SHALL deduplicate it by a Rails-derived account-scoped fingerprint and retain a first-class incident lifecycle, sanitized provenance, and audit trail.
- [ ] **OPERATIONAL-SUPERVISOR-006** — While `operational_supervisor` is disabled or running in shadow mode, the system SHALL not mutate admission, Auto-Pick, follow-up, queue priority, settings, or external systems.
- [ ] **OPERATIONAL-SUPERVISOR-007** — When the rollout guard is enabled for an authorized project, the system SHALL surface validated urgent incidents and supervisor last-success/last-failure state without requiring an external notification integration.
- [ ] **OPERATIONAL-SUPERVISOR-008** — Before any supervisor mitigation is enabled, the system SHALL require a separately accepted design decision, account-owner authorization, project opt-in, locked preconditions, idempotency, non-renewing expiry/recovery, revocation, rollback, audit, and focused verification.
