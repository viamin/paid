---
parent: PAID
prefix: OPERATIONAL-SUPERVISOR
---

# Low-Level Design: Operational Supervisor

## Purpose

The planned operational supervisor observes account-level delivery health. It
complements—not replaces—per-run anomaly detection, dispatch circuit breakers,
auto-pick gates, guardrails, PR escalation recovery, and Notification/Inbox.
Its first release observes and surfaces sanitized evidence only; it does not
alter execution.

## Boundary and data flow

`OperationalSupervisorJob` reads account setting
`operational_supervisor_mode`. `off` exits before snapshot construction or an
LLM call. In `shadow`, one account at a time flows through deterministic
`Snapshot`, `Analyze` through `agent_harness`, `ValidateFindings`, and
`PublishIncident`.

Snapshot membership/top-N ordering are deterministic and bounded. It excludes
all authored repository/user text, logs, prompts, summaries, raw errors,
credentials, secrets, and provider payloads. Semantic interpretation belongs
in the structured model response; Ruby enforces shape, budgets, policy,
authority, and record state rather than an opaque quality heuristic.

## Incident and lifecycle contract

`OperationalSupervisorIncident` is the account-scoped authority, holding a
stable fingerprint/version, permitted target IDs, sanitized evidence, status,
timestamps, validated recommendation, and model/prompt provenance. A unique
active fingerprint deduplicates sweeps. Notification is only a projection for
existing badge/Inbox policy; it cannot own action/recovery state.

V1 permits `open_incident_only`. A future action must have its own allowlisted
service with a row lock, current-state precondition, idempotency, least target
scope, human/configuration authority, before/after audit, explicit expiry, and
deterministic or human-approved recovery. It may not silently resume broad
automation.

## Metrics and rollout

The snapshot describes conversion, cost/tokens per merged PR, rework/follow-up
and commit counts, queue/stage age, categorized failures, guardrail/escalation/
anomaly counts, starvation, and supervisor availability. Every measure carries
window, denominator, provenance, freshness, or `insufficient_data`; an empty
denominator is not success.

`off` is the default. `shadow` has no delivery mutation path. Rollback returns
to `off` and retains sanitized audit evidence. Promotion to mitigation needs a
later accepted RDR amendment after shadow evidence, not a latent configuration
value.

## Decisions & alternatives

| Decision | Rationale | Alternative considered |
| --- | --- | --- |
| Dedicated incident with Notification projection | Durable lifecycle/provenance outgrow a dismissible notification while existing visibility is reused. | Make Notification the action record. |
| Account-scoped sanitized snapshots | Finds pipeline failures without exposing tenant content to a model. | Per-run-only anomaly analysis. |
| Shadow-only v1 | Establishes noise/false-positive evidence before granting authority. | Start by pausing PRs/projects. |
| LLM semantic classification, code policy | Preserves ZFC and auditability. | Hard-coded health/quality scoring. |

## Open questions

Retention, exact authorization UI/role, sampling caps/windows, shadow promotion
criteria, and any future action's enforcement primitive remain unresolved in
RDR-063 and block their implementation task.
