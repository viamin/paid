# EARS Specs: Operational Supervisor

> Planned requirements for RDR-063. Status: `[x]` implemented · `[ ]` active
> gap · `[D]` deferred. No runtime implementation exists yet.

- [ ] **OPERATIONAL-SUPERVISOR-001** — When an account mode is `off`, the
  system SHALL not build a snapshot, call an LLM, create an incident, or mutate
  delivery state for that account.
- [ ] **OPERATIONAL-SUPERVISOR-002** — When shadow mode builds a snapshot, it
  SHALL use only the allowlist and SHALL exclude authored user/repository
  content, logs, prompts, summaries, raw exception/provider text, credentials,
  and secrets.
- [ ] **OPERATIONAL-SUPERVISOR-003** — When a snapshot includes a metric, it
  SHALL retain its bounded window, denominator, provenance, and freshness or
  `insufficient_data` state.
- [ ] **OPERATIONAL-SUPERVISOR-004** — When selecting snapshot targets, the
  system SHALL use deterministic bounded ordering and SHALL not encode a
  semantic quality judgment in application heuristics.
- [ ] **OPERATIONAL-SUPERVISOR-005** — When analyzing a snapshot, the system
  SHALL call `agent_harness` with a fixed policy prompt and structured response;
  the model SHALL have no direct mutation capability.
- [ ] **OPERATIONAL-SUPERVISOR-006** — When output is malformed, unknown, or
  target/schema-invalid, the system SHALL not mutate delivery state and SHALL
  record only a bounded supervisor-health observation.
- [ ] **OPERATIONAL-SUPERVISOR-007** — When the same active finding recurs,
  the system SHALL deduplicate it by account-scoped fingerprint/version/target
  and update sanitized last-seen evidence.
- [ ] **OPERATIONAL-SUPERVISOR-008** — When persisting an incident, the system
  SHALL retain only sanitized evidence and model/prompt provenance and SHALL
  project it through Notification/Inbox/dashboard only within policy scope.
- [ ] **OPERATIONAL-SUPERVISOR-009** — When shadow mode is active, the system
  SHALL accept only `open_incident_only` and SHALL not change auto-pick,
  follow-up, queue priority, settings, or external systems.
- [ ] **OPERATIONAL-SUPERVISOR-010** — When an authorized operator views an
  incident, the system SHALL distinguish fresh, stale, unavailable, and
  insufficient supervisor evidence and expose last successful/failed sweep.
- [ ] **OPERATIONAL-SUPERVISOR-011** — When a later approved mitigation is
  implemented, it SHALL be separately allowlisted, precondition-checked,
  least-scoped, idempotent, audited, authorized, and have expiry/recovery.
- [ ] **OPERATIONAL-SUPERVISOR-012** — When rollout is disabled for rollback,
  the system SHALL stop future supervisor work without deleting required
  sanitized incident audit provenance.
