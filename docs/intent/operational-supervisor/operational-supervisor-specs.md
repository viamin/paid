# EARS Specs: Operational Supervisor

> Planned claims for RDR-063. `[ ]` means active implementation gap; none of these claims authorizes runtime mitigation.

- [ ] **OPERATIONAL-SUPERVISOR-001** — When building a delivery-health snapshot, the system SHALL include only the RDR-063 allowlisted operational identifiers, enums, bounded aggregates, and provenance, and SHALL exclude user/repository-authored content, paths, logs, prompts, summaries, raw exceptions, provider payloads, credentials, and secrets.
- [ ] **OPERATIONAL-SUPERVISOR-002** — When a rate is reported, the system SHALL retain its numerator, denominator, and window, and SHALL represent a missing or insufficient denominator as unavailable rather than zero.
- [ ] **OPERATIONAL-SUPERVISOR-003** — When selecting snapshot targets, the system SHALL use deterministic bounded ordering and cardinality limits, and SHALL NOT use a hard-coded semantic quality score or text heuristic.
- [ ] **OPERATIONAL-SUPERVISOR-004** — When analyzing a snapshot, the system SHALL use `agent_harness` only and SHALL provide the LLM no mutation tool, database access, shell access, GitHub access, or unfiltered source data.
- [ ] **OPERATIONAL-SUPERVISOR-005** — When analysis output is malformed, unknown, out of account scope, or names a target absent from the snapshot, the system SHALL fail closed, record only a sanitized supervisor-health result, and SHALL NOT change a delivery control.
- [ ] **OPERATIONAL-SUPERVISOR-006** — When a validated finding repeats for an account and fingerprint, the system SHALL update one tenant-scoped incident idempotently and preserve bounded sanitized provenance and audit linkage.
- [ ] **OPERATIONAL-SUPERVISOR-007** — When an authorized account operator resolves or dismisses an incident, the system SHALL record the decision and SHALL NOT infer that a project- or account-level delivery control was changed.
- [ ] **OPERATIONAL-SUPERVISOR-008** — When `operational_supervisor_shadow` is disabled, the system SHALL not schedule supervisor observation or publish a supervisor incident surface.
- [ ] **OPERATIONAL-SUPERVISOR-009** — When shadow observation is enabled by an authorized account administrator, the system SHALL create only sanitized incidents/audit records and SHALL NOT mutate admission, Auto-Pick, PR follow-up, queue priority, project settings, or external systems.
- [ ] **OPERATIONAL-SUPERVISOR-010** — Before any future mitigation is enabled, the system SHALL require a separately accepted action contract with narrow target authorization, current-state preconditions, row-locked idempotency, expiry or deterministic recovery, human reset, rollback, and tests; an LLM response SHALL never directly execute it.
