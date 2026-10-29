---
parent: PAID
prefix: OPERATIONAL-SUPERVISOR
---

# Low-Level Design: Operational Supervisor

> Companion to `docs/high-level-design.md` and RDR-063. This is proposed intent: no runtime supervisor behavior is shipped or enabled by this document.

## Purpose

The supervisor observes account-scoped delivery health without accessing customer/repository text or becoming an autonomous administrator. Its first release is a default-off shadow path: deterministic snapshot, `agent_harness` analysis, validated incident persistence, and operator visibility.

## Boundary and ownership

The snapshot builder is the sole data boundary. It emits only typed identifiers, enums, counts, rates, ages, and numeric cost/token aggregates with documented windows and denominators. It excludes all authored content, logs, prompts, raw errors, credentials, secrets, and raw provider responses. The LLM receives only that result through `agent_harness`; it does not write state or select its own targets. Rails validates every response and derives fingerprints.

Quality/delivery semantics are structured LLM judgments. Rails may aggregate facts, bound payloads, validate schemas, enforce authorization, and apply mechanical limits, but may not encode semantic quality scoring heuristics.

## Enablement scope

The project feature flag is the sole gate. An account snapshot contains only
facts from projects for which `FeatureFlags.enabled?(:operational_supervisor,
project:)` is true at collection time; account-level rollups derive only from
that enabled-project set. A disabled project's facts cannot be snapshotted or
sent to `agent_harness`, and it cannot be an incident target or appear in a
supervisor projection. When an account has no enabled projects, the supervisor
does not construct a snapshot, invoke an LLM, create or update an incident, or
project supervisor state. Visibility is limited to authorized operators and
the enabled projects represented by the finding.

## Persistence and projection

Dedicated `SupervisorSnapshot` and `SupervisorIncident` records are durable.
Each snapshot retains its bounded typed sanitized digest, included-project and
metric provenance, creation time, and retention expiry, and is purged when its
recorded retention interval expires. The incident owns lifecycle, target IDs,
sanitized evidence, fingerprint, provenance, retention, and action audit.
Notifications and Inbox/dashboard entries project those records where they
meet the existing severity and access contracts; they are not substitutes for
the incident lifecycle.

## Rollout and future action

`operational_supervisor` is default-off. A project opt-in enables only shadow observation after verification. Disabling it stops future snapshot construction, LLM analysis, incident creation or update, and supervisor projection for that project while preserving auditable sanitized records. A separately defined availability health check may report that the supervisor is disabled, but cannot perform supervisor analysis or modify supervisor records. A later action requires an accepted RDR amendment, account-owner authorization, project opt-in, locked preconditions, incident idempotency, audit records, expiry/recovery, revocation, rollback, and tests. It cannot inherit authority from an incident or from an LLM recommendation.

## Decisions & Alternatives

| Decision | Chosen | Alternatives Considered | Rationale |
|----------|--------|------------------------|-----------|
| Source of truth | Dedicated `SupervisorSnapshot` and `SupervisorIncident` records | Reuse Notifications or Inbox entries as the lifecycle record | Snapshots and incidents require bounded typed evidence, provenance, fingerprint-based deduplication, retention, and an action audit that projection records do not own. Notifications and Inbox entries can remain rebuildable access-controlled projections. |
| Enablement scope | Default-off `operational_supervisor` project flag; account rollups use only enabled projects | Account-wide flag, implicit account enablement, or collecting all projects and filtering later | The project flag supplies a narrow, revocable authorization boundary before collection. It prevents a disabled project's facts, targets, and projections from entering the supervisor path and permits a limited shadow pilot. |
| Initial operating mode | Shadow-only observation with validated findings and operator visibility | Immediate automated mitigation, a recommendation that inherits incident authority, or deterministic Rails quality scoring | The first release must establish whether sanitized delivery-health signals are useful without changing delivery behavior. Semantic interpretation remains advisory through `agent_harness`; Rails retains mechanical validation and policy enforcement. |

## Open Questions & Future Decisions

### Resolved

1. ✅ Persist supervisor snapshots and incidents separately from Notifications and Inbox projections so their lifecycle, retention, provenance, and audit obligations remain recoverable.
2. ✅ Gate observation at the project boundary with a default-off flag; no enabled projects means no supervisor snapshot, analysis, incident, or projection work.
3. ✅ Defer all mitigation until shadow evidence supports a separately accepted RDR amendment and the required authority and recovery controls are designed.

### Deferred

1. Select concrete snapshot and incident retention intervals after schema and operational-volume evidence exists.
2. Define the authorized operator roles and exact dashboard/Inbox projection behavior with the incident contract.
3. After shadow evidence, decide whether an explicitly authorized mitigation candidate merits a separate RDR amendment; no action is presumed approved.

## Delivery order

The held issue tree is #4708: #4709 incident contract and #4710 snapshot; #4711 analysis after both; #4712 shadow schedule/surface after #4709/#4711; #4713 separately decides any mitigation; #4714 verifies evidence without closing the epic. The implementation must follow this LLD and its EARS claims.
