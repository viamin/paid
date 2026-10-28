---
parent: PAID
prefix: OPERATIONAL-SUPERVISOR
---

# Low-Level Design: Operational Supervisor

> Planned implementation for RDR-063. No runtime supervisor exists yet.

## Purpose

The supervisor gives account operators a privacy-bounded view of delivery health across runs, PR progression, queues, cost, and existing guardrails. Its initial contract is observation only: it creates an operational incident after validating a sanitized `agent_harness` classification and cannot alter work.

## Boundary and flow

`OperationalSupervisor::BuildSnapshot` deterministically reads only allowlisted operational fields and produces an account-scoped, bounded JSON document. `OperationalSupervisor::Analyze` supplies that document to `agent_harness` with a fixed structured schema. `ValidateFinding` checks the returned shape, target membership, and enum values. `UpsertIncident` owns dedupe, lifecycle, and audit linkage. The dashboard/Inbox projection reads that incident; it is not an alternate persistence model.

The builder excludes all authored repository/user material, paths, logs, prompts, summaries, raw exceptions, provider payloads, credentials, secrets, and free-form metadata. It may include target identifiers, enum states, timestamp buckets, bounded counts, totals, and rates with provenance.

## Incident contract

A first-class, account-scoped incident is required because Notification does not own repeated-observation, snapshot provenance, action provenance, or expiry/recovery lifecycle. Its stable fingerprint is unique within an account; updates are idempotent under a row lock. Evidence remains sanitized and bounded. Permitted lifecycle states are `open`, `waiting_for_human`, `resolved`, and `dismissed`; authorized account operators make manual terminal changes, each with an audit record.

## Judgment and policy split

Mechanical Rails code owns tenant isolation, data allowlisting, time windows, cardinality, rate arithmetic, target membership, schema validation, dedupe, authorization, and rollout gates. `agent_harness` alone makes semantic pattern classification from the sanitized facts. There is no quality score, title/text classifier, or hard-coded incident threshold. A zero denominator is represented as unavailable, never silently as zero.

## Rollout and future actions

`operational_supervisor_shadow` is default-off. An account administrator must explicitly enable the account before an eligible project can evaluate the flag. While it is enabled, the only allowed side effect is sanitized incident/audit creation and the operator projection. Disabling it stops future observation; it does not delete incident history.

There is no action adapter in this segment. A later action needs an accepted RDR amendment and its own selected target, owner service, authorization, fresh-state precondition, idempotency lock, expiry or deterministic recovery, human reset, rollback, and tests. The supervisor LLM never writes directly.

## Decisions & Alternatives

| Decision | Rationale | Alternative considered |
| --- | --- | --- |
| Dedicated incident ledger | Preserves lifecycle/provenance without distorting Notification's narrow contract. | Extend `Notification`; rejected because it lacks the required ownership fields. |
| Shadow-only first release | Produces evidence without changing delivery controls. | Start with pause/reprioritize actions; rejected pending action-specific review. |
| Aggregate-only LLM input | Meets the client-content/privacy boundary. | Send logs or repository context; prohibited. |

## Open Questions & Future Decisions

- Select individual mitigation actions only after shadow evidence, with a separately accepted RDR amendment (#4713).
- Set retention duration with the data-retention owner (#4709).
- Set snapshot bounds from capacity evidence rather than quality heuristics (#4710).
