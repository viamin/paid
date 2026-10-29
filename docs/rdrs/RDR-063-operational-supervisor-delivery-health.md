# RDR-063: Operational Supervisor for Delivery Health

> Draft for normal design review. This record does not authorize runtime implementation, mitigation, or enablement.

## Metadata

- **Date**: 2026-10-29
- **Status**: Draft
- **Type**: Operations + AI Safety + Automation
- **Priority**: P3
- **Related RDRs**: [RDR-011](RDR-011-observability.md), [RDR-047](RDR-047-work-category-queue-priority.md), [RDR-049](RDR-049-configuration-health-checks.md), [RDR-077](RDR-077-automation-phases-and-work-item-authorization.md)
- **Related Intent**: [Operational Supervisor LLD](../intent/operational-supervisor/operational-supervisor-design.md) and [EARS](../intent/operational-supervisor/operational-supervisor-specs.md)
- **Related Issues**: [#4341](https://github.com/viamin/paid/issues/4341) (planning); [#4708](https://github.com/viamin/paid/issues/4708) (epic); [#4709](https://github.com/viamin/paid/issues/4709), [#4710](https://github.com/viamin/paid/issues/4710), [#4711](https://github.com/viamin/paid/issues/4711), [#4712](https://github.com/viamin/paid/issues/4712), [#4713](https://github.com/viamin/paid/issues/4713), [#4714](https://github.com/viamin/paid/issues/4714)
- **Related Tests**: `spec/services/operational_supervisor/` (planned; see OPERATIONAL-SUPERVISOR EARS)

## Problem and current evidence

Paid already detects and surfaces important local conditions: `AgentRunAnomaly` records statistical per-run outliers; `Guardrails::ViolationHandler` stops or pauses a run; notification severity and blocking notifications route actionable work to the Inbox; PR follow-up limits, queue priority, stale-run recovery, configuration health checks, execution audit events, and dashboard caches provide further bounded primitives. None is an account-level, sanitized, delivery-health supervisor, and there is no `OperationalSupervisor` runtime implementation.

The missing capability is observation of whether delivery is degrading across the issue-to-PR lifecycle. It is not permission to infer code quality in Rails, to inspect customer/repository data, or to mitigate automatically.

## Decision

Select a staged, account-scoped design:

1. First ship only a disabled-by-default **shadow observation** path: deterministic sanitized snapshots, `agent_harness` semantic classification, durable incidents, and authorized operator visibility.
2. Store supervisor incidents and snapshots as first-class records. Existing Notifications and Inbox entries are rebuildable projections, not the source of truth, because they cannot provide the required typed provenance, lifecycle, dedupe, retention, and future mitigation audit trail.
3. Defer every autonomous action. After shadow evidence, a separately reviewed amendment may select either existing PR escalation or one supervisor-owned, expiring Auto-Pick-only new-issue-admission lease. The valid decision is to keep observation-only mode.

External notification delivery is out of scope. Urgent visibility must work in the Paid dashboard/Inbox without Slack, email, webhooks, or PagerDuty.

## Data and LLM boundary

The snapshot builder is deterministic Rails code. It may include account, project, issue, PR, and run IDs; UI-visible repository slugs; enum/count/rate rollups; lifecycle ages; queue depth; token/cost aggregates; guardrail, anomaly, escalation, and phase-count aggregates; and explicit measurement windows and denominators. Its top-N selection is bounded and mechanically ordered by documented numeric facts.

It MUST NOT include user-authored or repository-authored content: issue/PR titles or bodies, comments, review threads, commit messages, diffs, paths, file content, prompts, agent output, logs, summaries, raw exception text, names/emails, credentials, tokens, secrets, or raw provider responses. Rails must validate both snapshot and persisted evidence against this allowlist.

`agent_harness` is the only application LLM interface. The LLM can classify a sanitized pattern and recommend a catalog item through a strict schema. Rails owns tenant isolation, schema validation, target membership, fingerprinting, preconditions, idempotency, authorization, all writes, and all mutations. Malformed, unknown, or unauthorized output fails closed: record only a sanitized supervisor-health result and make no operational mutation.

Mechanical aggregation and safety limits may be deterministic. No hard-coded score or threshold may decide that a delivery pattern is "good", "bad", or "quality regression"; that semantic judgment belongs to the structured LLM result and remains advisory during shadow mode.

## Incident, metrics, and lifecycle

`SupervisorSnapshot` retains a bounded, typed, sanitized digest and metric provenance. `SupervisorIncident` retains a Rails-derived fingerprint, affected IDs, sanitized evidence, severity/category, status (`open`, `waiting_for_human`, `mitigated`, `resolved`, `dismissed`), first/last seen timestamps, model/prompt/policy identities, and an append-only action/audit trail. It deduplicates per account and fingerprint; it never retains raw model output.

Metrics must name their window, denominator, inclusion rule, and unavailable state. Initial metrics are issue-to-PR conversion, PR-to-merge conversion, cost per merged PR, rework runs per PR, Paid-authored PR commit count, stage age, guardrail/escalation rate, and queue starvation. A zero or unavailable denominator is represented as unavailable, never as success or failure.

## Future mitigation boundary

No action is enabled by this RDR. If post-shadow review selects a candidate, the implementation must require account-owner authorization, project opt-in, locked current-state preconditions, an incident-scoped idempotency key, execution audit records, explicit rollback, and a non-renewing expiry/recovery path. It must preserve PR continuation and recovery and must not mutate user scheduler settings. Rejected candidates are scheduler pause reuse, follow-up cap mutation, queue reprioritization, account-wide pause, recovery-job enqueue, and external notification delivery.

## Rollout Guard

The implementation SHALL define `operational_supervisor` in `FeatureFlags::DEFINITIONS`, default off, and read it through `FeatureFlags.enabled?(:operational_supervisor, project:)`. The authorized project feature-flag surface is the only enablement surface. A pilot may enable shadow observation only after the snapshot boundary, incident contract, authorization, dashboard projection, and supervisor health checks are verified.

Rollback disables the flag and stops future analysis; it does not erase sanitized incident/audit evidence. Cleanup removes the flag only after final audit verifies the accepted default posture, retention/reconciliation behavior, and any separately approved mitigation path. No mitigation can be enabled by rolling out shadow mode.

## Measurable acceptance

- Fixture-backed boundary tests prove forbidden content cannot enter snapshots, LLM prompts, incidents, audit evidence, or projections.
- Shadow mode is default-off and cannot mutate admission, Auto-Pick, follow-up, queue priority, settings, or external systems.
- Validated findings are account-scoped, deduplicated, auditable, and visible to authorized operators with last-success/last-failure supervisor health.
- Unknown LLM fields, invalid targets, and failed authorization/preconditions produce no mutation.
- Metric windows, denominators, unavailable states, deterministic top-N bounds, and retention are tested.
- Any later action has dedicated authorization, precondition, idempotency, expiry/recovery, revocation, rollback, and focused test evidence.

## Implementation tree and holds

The canonical tree is [#4708](https://github.com/viamin/paid/issues/4708), which Tracks this planning issue without closing it: #4709 incident/audit contract and #4710 snapshot depend on #4341; #4711 analysis depends on both; #4712 shadow scheduling/surface depends on #4709 and #4711; #4713 is the held, non-authorizing post-shadow mitigation decision; #4714 is the terminal evidence audit. All are P3 with a `planning` hold. Earlier duplicate trees were superseded and closed as not planned.

The tree remains held until this RDR and its HLD → LLD → EARS arrow are merged and accepted. #4714 Tracks the epic without closing it and may recommend closure only after it verifies shipped code, tests, documentation, rollout/cleanup, and approved acceptance; closed children alone are not evidence.

## Unresolved decisions

- Select precise snapshot retention limits after schema and operational volume evidence exist.
- Select the authorized operator roles and exact dashboard/Inbox projection behavior with the incident contract.
- Decide, after shadow evidence, whether either mitigation candidate warrants a separate accepted amendment; neither is presumed approved.
