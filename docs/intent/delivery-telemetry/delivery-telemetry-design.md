---
parent: PAID
prefix: DELIVERY-TELEMETRY
---

# Low-Level Design: Human-led Delivery Telemetry

## Purpose

Project operators need a queryable, read-only view of how human approval
affects delivery. The report reuses lifecycle records owned by feature
approval and intent conformance; it neither records a telemetry event nor
changes admission, approval, release, or merge behavior.

## Report contract

`DeliveryTelemetry::ProjectReport` accepts a project and an optional
enforcement activation time. It returns completed-feature cycle records,
approval-loop aggregates, escaped-drift aggregates, and delivery-time
comparison data.

For a completed feature, the report follows the earliest linked
`create_feature` run start through the first recorded approval, the release
audit event, and the final merged linked implementation PR. It reports
resolved human decisions and cleared deterministic approval blockers as
human-touch counts. A feature without every endpoint remains visible but has
no completed cycle duration.

Approval-loop time-to-clear is calculated from the persisted decision creation
and resolution timestamps, grouped by the corresponding readiness blocker
code. Vague-criteria rate is the proportion of evaluated feature intents whose
persisted clarity state is `vague`; the report labels the configured criteria
reviewer model and prompt identity rather than inventing per-evaluation
provenance that was not stored. Stale-approval churn compares every immutable
approval revision's `pr_heads` snapshot with the currently synchronized design
PR heads, per feature intent.

Escaped drift is continuous: its denominator is merged linked PRs whose latest
conformance verdict is `within_scope`, and its numerator is the subset
subsequently superseded by a `merged` design amendment for that verdict's
approved design revision. The amendment's `merged_at` records when the
material design change landed. The same calculation is grouped by the latest
verdict's reviewer model. The report also discloses whether the
`approved_intent_amendments` flow is enabled for the project, so an operator
does not interpret a zero from a project unable to record amendments as an
observed absence of drift.

Delivery time is PR `github_created_at` to local terminal `closed_at` (or the
last synchronized timestamp for legacy terminal rows), matching the rollout
worksheet. Supplying the project's enforcement activation timestamp partitions
the same project population into pre-activation baseline and post-activation
samples.

## Boundaries

The report is aggregation only. It does not add columns, callbacks, jobs, or
writes to an agent-run, readiness, approval, release, or merge path. It reads
only project-scoped records and does not infer semantic drift from text.

## Decisions & Alternatives

| Decision | Rationale | Alternative considered |
| --- | --- | --- |
| Query-time report | Source lifecycle records are authoritative and avoid a hot-path write. | Materialized telemetry rows would require invalidation and new writes. |
| Amendment as escaped-drift signal | An amendment already records that an approved baseline was superseded after merge. | Keyword matching follow-up issue text would be semantic inference and violate ZFC. |
