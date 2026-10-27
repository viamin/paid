---
parent: PAID
prefix: OPERATIONAL-SUPERVISOR
---

# Low-Level Design: Operational Supervisor

The guarded, account-scoped supervisor converts deterministic sanitized operational facts into durable incidents and a dashboard surface. Its first release is observational: no mitigation executes.

`Snapshot` builds a bounded, versioned allowlist. `Analyze` calls only `agent_harness` with a fixed structured contract. `ValidateFinding` rejects prohibited fields, unknown values, out-of-snapshot IDs, and every action except `open_incident_only`. `OperationalIncident` owns lifecycle, fingerprint, evidence, and provenance; notification/Inbox integration is presentation only.

No user or repository content, logs, prompts, summaries, secrets, credentials, raw provider responses, or unclassified exception text crosses the analysis boundary. Candidate bounds are mechanical and never semantic quality scoring.

Incidents progress from `observed` to `waiting_for_human`, `resolved`, or `dismissed`. Two healthy snapshots may resolve an observed incident. Future actions require rechecked preconditions, narrow scope, idempotency, audit, recovery, and a new approved decision; they cannot reuse `auto_continue_paused`.

`operational_supervisor_read_only` defaults off and gates all scheduling/analysis. Disable stops future work and retains audit records.

## Decisions & Alternatives

| Decision | Chosen | Alternative | Rationale |
| --- | --- | --- | --- |
| Incident storage | `OperationalIncident` | Extend `Notification` | Lifecycle and provenance exceed notification semantics. |
| v1 action | `open_incident_only` | Autonomous pauses/cap changes | Existing controls are safety-critical. |
| Candidate selection | Bounded mechanical facts | Quality score | Semantic judgment belongs to the model. |
