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

## Delivery order

The held issue tree is #4708: #4709 incident contract and #4710 snapshot; #4711 analysis after both; #4712 shadow schedule/surface after #4709/#4711; #4713 separately decides any mitigation; #4714 verifies evidence without closing the epic. The implementation must follow this LLD and its EARS claims.
