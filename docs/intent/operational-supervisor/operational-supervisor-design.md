---
parent: PAID
prefix: OPERATIONAL-SUPERVISOR
---

# Operational supervisor design

The Operational Supervisor is an opt-in operational safety loop over sanitized delivery statistics. It observes account delivery health without reading user, repository, or agent-produced content; an LLM classifies bounded facts through `agent_harness`, while Rails owns every persistence, policy, authorization, and mutation decision.

## Snapshot and incident boundary

`OperationalSupervisor::Snapshot` produces a versioned, account-scoped JSON document containing only allowed numeric aggregates, enum categories, ages, and Paid-local numeric identifiers. It represents unavailable measurements as unavailable. It has no path to issue/PR text, repository data, prompts, logs, summaries, credentials, raw exceptions, or provider responses.

`SupervisorIncident` is the durable operational record; `Notification` remains a secondary consumer surface. A separate `SupervisorMitigation` records each action and reversal so incident evidence, action state, expiry, and audit trail are independently queryable. Critical and warning open incidents render above dashboard metrics for authorized operators.

## Decision and actuation boundary

`OperationalSupervisor::Analyze` calls `agent_harness` with the snapshot, a versioned fixed policy prompt, catalog data, and a JSON schema. Its output is a recommendation, never authority. `ValidateFinding` rejects malformed output, unknown enum values, unknown targets, stale snapshots, duplicate fingerprints, and failed policy checks. `ApplyMitigation` locks and rechecks its target before creating the narrowly-scoped overlay and execution audit event.

The first catalog contains `pause_pr_followups`, `pause_project_autopick`, and `open_incident_only`. The first two are new overlay controls rather than edits to user configuration or broad project pauses. Each has one active mitigation per target/action, a bounded expiry, and a recorded reversal. Meaningful progress is not inferred as a recovery signal; expiry is a mechanical clock and a human-visible incident remains.

## Policy and rollout

The account flag `operational_supervisor_enabled` defaults false. Analysis and actuation require it; actuation also requires the account policy record and the target project opt-in. Account administrators manage policy, and project administrators can resolve a mitigation in their project. Shadow-mode snapshot work produces neither LLM calls nor actions. Flag disablement halts new work; the rollback path reverses supervisor-owned overlays without touching existing user or guardrail controls.

Metric denominators and spend/volume admission thresholds are versioned operator policy. Code computes those declared measures and enforces limits; it does not encode a quality or semantic score. The model interprets the supplied facts within the schema and catalog.

## Decisions & Alternatives

| Decision | Chosen | Alternatives considered | Rationale |
| --- | --- | --- | --- |
| Incident persistence | `SupervisorIncident` plus `SupervisorMitigation` | Extend `Notification` | Incidents need independently auditable finding/action/expiry lifecycle without changing user notification semantics. |
| Initial action scope | Two narrow admission overlays plus incident-only | Broad pause, priority mutation, cap mutation, termination | Existing controls are reused without altering configured policy or unrelated work. |
| Recovery | Bounded expiry with recorded reversal | Infer meaningful progress; human-only reset | Clock-based expiry is mechanical and reviewable; semantic progress inference is not. |
| Analysis input | Sanitized aggregate snapshot | Logs, content, repository data | Operational classification does not need client or repository content and must preserve its privacy boundary. |

## Open questions and future decisions

- Retention and export rules for sanitized incident evidence require a privacy review before implementation.
- External subscriber channels are out of scope until the internal incident lifecycle has production evidence.

## References

- `docs/rdrs/RDR-063-operational-supervisor-delivery-health.md`
- `docs/intent/notification-severity/`
- `docs/intent/project-dashboard-metrics/`
