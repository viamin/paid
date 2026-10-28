---
parent: PAID
prefix: OPERATIONAL-SUPERVISOR
---

# Low-Level Design: Operational Supervisor

## Purpose

The Operational Supervisor gives authorized operators an account-scoped,
auditable view of delivery-health patterns without exposing customer or
repository content to its LLM and without granting the initial release any
delivery-control authority. [RDR-063](../../rdrs/RDR-063-operational-supervisor-delivery-health.md)
owns the decision and rollout boundary.

This segment is planned, not implemented. Its unchecked EARS claims describe
the contract implementation must preload after design review accepts the RDR.

## Boundaries and Components

`OperationalSupervisor::BuildSnapshot` mechanically aggregates typed,
account-scoped facts through a versioned field allowlist. It records source
availability, metric cohorts, a payload digest, and bounded factual rankings;
it never reads free-text issue, repository, log, prompt, exception, provider,
or credential fields.

`OperationalSupervisor::AnalyzeSnapshot` sends only that payload and the
versioned policy/catalog through `agent_harness`. The model owns semantic
category, severity, explanation, and recommendation. Rails owns JSON-schema
validation, citations, target membership, freshness, authorization,
idempotency, and mutation policy.

`SupervisorIncident` is the durable source of truth. Notifications and Inbox
items are rebuildable presentation projections. An incident reconciler owns
first/last seen state, sanitized evidence, resolution, and analysis provenance.

`OperationalSupervisorSweepJob` is gated by the persisted account
`operational_supervisor_mode`. `off` does nothing. `shadow` permits observation
and incident publication but rejects all mutating actions at dispatch.

## Metrics and Judgment

Snapshot metrics are factual observations with explicit windows, cohorts,
numerators, denominators, and unavailable states. Distribution deltas and
top-N selection are mechanical descriptions and payload bounds. There is no
composite health score and no Rails threshold that converts a statistic into a
quality, profitability, or action judgment.

The LLM may make those semantic judgments from the sanitized facts. A response
is advisory until Rails validates its structure and policy. A confidence value,
if retained for calibration, is evidence for review rather than an autonomous
authorization threshold.

## Persistence and Lifecycle

Snapshots retain a versioned sanitized JSON payload for a bounded period.
Incidents retain a stable Rails-derived fingerprint, account and allowed target
references, lifecycle, cited sanitized facts, snapshot digest, first/last-seen
timestamps, and model/prompt/policy versions. Raw model output is not retained.

Incidents move among `open`, `waiting_for_human`, `mitigated`, and `resolved`.
One missing observation does not resolve an incident. Resolution comes from a
validated healthy reconciliation, an authorized operator, or a typed source
becoming inapplicable. Dismissal affects a user's projection, not the audit
record.

## Authorization and Future Actions

Existing account/project policies scope reads. Account owners control mode,
retention, and any future action grant. Project administrators may only opt a
project into an account-granted action and revoke its project lease.

The initial catalog contains only `open_incident`. The held future candidates
are `escalate_pr` and a supervisor-owned, expiring
`suspend_project_new_issue_admission` lease. Each requires a reviewed RDR
amendment, current account grant/project opt-in, locked live-state recheck,
idempotent receipt, audit event, and explicit recovery. The admission lease is
checked by Auto-Pick only; it does not change scheduler settings or block PR
continuation. No lease can renew itself.

## Decisions and Alternatives

| Decision | Alternatives | Rationale |
| --- | --- | --- |
| Dedicated snapshot/incident records with Notification projection | Extend Notification as source of truth | Notification lacks immutable snapshot provenance, repeated observation, and future lease/recovery semantics. |
| Observation-only initial catalog | Ship broad autonomous mitigation; hard-code known thresholds | Shadow evidence is required before authority is justified, and semantic degradation belongs to the LLM. |
| Typed allowlist serializer | Serialize models then redact forbidden keys | Positive selection makes the privacy boundary testable and fails closed. |
| Account snapshot with explicit project rows | Global snapshot; one LLM call per project | Account scope supports cross-project patterns while retaining tenant isolation and bounded payloads. |
| Auto-Pick-only future lease | Reuse project scheduler pause | Scheduler pause also blocks continuations/recovery and is too broad. |

## Rollout and Recovery

The named persisted guard is `operational_supervisor_mode`, default `off`.
Shadow enablement is account-owner controlled and allowlisted during the pilot.
Rollback changes the mode to `off`; future active leases are separately revoked
through their audited recovery path. Incidents and receipts remain under their
retention policy.

Promotion criteria, pilot sample, retention, and any future action must be
accepted before the relevant rollout begins. Implementation issue closure is
not rollout evidence; #4714 performs the terminal audit against shipped code,
tests, documentation, and live guard state.

## Dependencies and Ownership

- Notification severity owns bell/Inbox classification, not incident truth.
- Auto-Pick owns new-issue admission enforcement.
- RDR-047 queue priority remains authoritative; the supervisor cannot reorder.
- Existing guardrail and recovery services keep their local policy ownership.
- `agent_harness` is the only application LLM interface.

## Open Questions

- Design review must approve retention and a future lease safety ceiling.
- Pilot promotion measures must be predeclared before shadow enablement.
- Post-shadow review may reject both candidate actions.
- Inbox projection timing remains a calibration decision; dashboard visibility
  is required in the initial release.
