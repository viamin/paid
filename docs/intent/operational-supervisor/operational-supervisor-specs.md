# EARS Specs: Operational Supervisor

> Planned claims for RDR-063. `[ ]` means an active implementation gap; none of
> these claims represents shipped behavior merely because the design exists.

- [ ] **OPERATIONAL-SUPERVISOR-001** — While an account's
  `operational_supervisor_mode` is `off`, the system SHALL NOT build a
  supervisor snapshot, call an LLM, publish a supervisor incident, or dispatch
  a supervisor action.
- [ ] **OPERATIONAL-SUPERVISOR-002** — When a supervisor snapshot is built,
  the system SHALL use a versioned positive field allowlist and SHALL exclude
  all issue/PR/review/commit text, repository paths or contents, prompts, chat,
  stdout/stderr/logs/summaries, raw exception/provider text, arbitrary metadata,
  user identity fields, credentials, tokens, and secrets.
- [ ] **OPERATIONAL-SUPERVISOR-003** — When delivery-health metrics are
  included, the system SHALL record each metric's window, cohort, numerator,
  denominator, source availability, and unavailable state, and SHALL NOT
  represent a missing denominator as zero.
- [ ] **OPERATIONAL-SUPERVISOR-004** — When bounding a snapshot, the system
  SHALL rank detail rows only by disclosed factual quantities, retain aggregate
  remainder counts, and SHALL NOT use a hard-coded score or threshold to label
  delivery quality or select an action.
- [ ] **OPERATIONAL-SUPERVISOR-005** — When analyzing a snapshot, the system
  SHALL send only the sanitized snapshot and versioned policy/schema/catalog
  through `agent_harness`; it SHALL NOT call a provider API directly.
- [ ] **OPERATIONAL-SUPERVISOR-006** — When model output is malformed,
  unknown, stale, uncited, cross-account, targets an ID absent from the
  snapshot, or recommends an action outside the active catalog, the system
  SHALL reject it without mutating delivery state.
- [ ] **OPERATIONAL-SUPERVISOR-007** — When a validated finding is reconciled,
  the system SHALL persist or update one account-scoped incident using a
  Rails-derived fingerprint, sanitized evidence, snapshot digest,
  first/last-seen timestamps, and model/prompt/policy versions, and SHALL NOT
  persist the raw model response.
- [ ] **OPERATIONAL-SUPERVISOR-008** — When an incident is published for an
  authorized operator, the system SHALL show warning/critical incidents above
  live dashboard metrics and expose last-attempted/last-successful supervisor
  health without requiring an external notification service.
- [ ] **OPERATIONAL-SUPERVISOR-009** — While an account is in `shadow` mode,
  the system MAY build snapshots, call `agent_harness`, and publish incidents,
  but SHALL reject every action that changes delivery or external state.
- [ ] **OPERATIONAL-SUPERVISOR-010** — When an equivalent finding repeats,
  the system SHALL update its existing incident; when one analysis omits the
  finding, the system SHALL NOT resolve it solely from that omission.
- [ ] **OPERATIONAL-SUPERVISOR-011** — If a future reviewed amendment enables
  an action, the system SHALL require a current account-owner grant, applicable
  project opt-in, locked live revalidation, an incident/action/target
  idempotency key, and before/after execution audit receipts.
- [ ] **OPERATIONAL-SUPERVISOR-012** — If a future reviewed amendment enables
  `suspend_project_new_issue_admission`, the system SHALL create a bounded
  Auto-Pick-only lease, continue to admit PR continuation/recovery, SHALL NOT
  change scheduler pause settings, and SHALL expire or permit authorized early
  revocation without self-renewal.
- [ ] **OPERATIONAL-SUPERVISOR-013** — When an authorized operator sets mode
  to `off`, the system SHALL stop new scheduling and action dispatch, preserve
  retained incidents/audit receipts, and expose an audited lease recovery path.
- [ ] **OPERATIONAL-SUPERVISOR-014** — Before the implementation epic can be
  accepted, the terminal audit SHALL verify shipped behavior, tests,
  documentation, rollout evidence, and every enabled action's safety contract;
  it SHALL NOT infer acceptance from closed child issues.
