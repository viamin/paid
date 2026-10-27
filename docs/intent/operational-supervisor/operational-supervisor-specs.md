# EARS Specs: Operational Supervisor

- [ ] **OPERATIONAL-SUPERVISOR-001** — Where `operational_supervisor_read_only` is disabled, the system SHALL not create a supervisor snapshot, invoke an LLM, or mutate delivery state.
- [ ] **OPERATIONAL-SUPERVISOR-002** — When the supervisor builds a snapshot, the system SHALL include only versioned allowlisted identifiers and aggregate facts and SHALL exclude user/repository content, logs, prompts, summaries, secrets, credentials, raw provider responses, and unclassified exception text.
- [ ] **OPERATIONAL-SUPERVISOR-003** — When analyzing a snapshot, the system SHALL use `agent_harness` and SHALL provide no database, shell, GitHub, or action-execution capability to the model.
- [ ] **OPERATIONAL-SUPERVISOR-004** — If a response is malformed, unknown, out-of-snapshot, or proposes an action other than `open_incident_only`, then the system SHALL fail closed and SHALL not mutate delivery controls.
- [ ] **OPERATIONAL-SUPERVISOR-005** — When a finding matches an open fingerprint, the system SHALL update sanitized evidence and provenance without creating a duplicate incident.
- [ ] **OPERATIONAL-SUPERVISOR-006** — When an authorized user views incidents, the system SHALL expose only authorized incidents and SHALL render open critical/warning incidents above dashboard live metrics.
- [ ] **OPERATIONAL-SUPERVISOR-007** — When two consecutive completed snapshots are healthy for an observed incident, the system SHALL resolve it without changing any run, queue, PR, auto-pick, or follow-up control.
