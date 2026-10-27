# RDR-063: Operational Supervisor for Delivery Health

## Metadata

- **Date**: 2026-10-27
- **Status**: Draft — pending normal design review
- **Type**: Operations + AI Safety
- **Priority**: P3
- **Related Intent**: [`operational-supervisor`](../intent/operational-supervisor/operational-supervisor-design.md) (`OPERATIONAL-SUPERVISOR-001`–`007`)
- **Related Issues**: #4341 (planning), #4687 (umbrella), #4688 (snapshot), #4689 (analysis), #4690 (surface), #4691 (audit)
- **Related Tests**: Planned in #4688–#4690; none exist because this is planning-only.

## Evidence and decision

Paid already ships narrower primitives: per-run `Anomalies::Detect`, durable notifications and the operator Inbox, PR escalation recovery, tenant-scoped `ExecutionControl`, and read-only delivery telemetry. No account-wide `OperationalSupervisor` implementation or prior RDR-063 implementation tree exists. These primitives are reused; this RDR does not replace their deterministic safety limits.

The selected v1 scope is a guarded, **read-only incident pilot**. A scheduled account-scoped service builds a deterministic sanitized snapshot, calls an LLM only through `agent_harness`, validates a structured finding, persists a first-class incident, and renders it above dashboard metrics. It must not pause work, alter auto-pick or follow-up caps, enqueue recovery, or contact external systems.

## Privacy, storage, and metrics

`OperationalIncident` is dedicated storage, rather than an overloaded `Notification`, because incident fingerprinting, lifecycle, affected identifiers, sanitized evidence, analysis provenance, and future mitigation provenance have independent audit needs. Notifications and Inbox may be derived presentation surfaces.

The snapshot is deterministic Rails code, account scoped, bounded, versioned, and field-allowlisted. It contains only Paid-visible identifiers and aggregate/count/rate/age/enumerated-state facts. It excludes issue/PR text, comments, commit data, repository content and paths, prompts, logs, agent summaries, credentials, secrets, raw provider responses, and unclassified exception text.

Metrics are facts, not a hard-coded quality verdict: conversion, merged-PR cost/rework denominators, queue/stage ages, outcome counts, guardrail/escalation counts, and continuation-versus-new-work composition. Each reports its window, denominator, and unavailable state. Mechanical candidate bounds do not score semantic quality; the model can describe a pattern but Rails cannot branch on a semantic quality label.

## Actions, authorization, recovery

The v1 action catalogue contains only `open_incident_only`; Rails rejects every other action. Any future mitigation requires an accepted RDR amendment, new LID artifacts, existing-scope authorization, deterministic current-state preconditions, idempotency, audit data, narrow scope, expiry/recovery semantics, and rollout review. It may not repurpose operator-owned `auto_continue_paused`.

Incident states are `observed`, `waiting_for_human`, `resolved`, and `dismissed`. Matching evidence updates an open fingerprint. Two consecutive healthy completed snapshots may resolve an observed incident; dismissal is an authorized human decision. No mitigation expiry exists in v1 because no mitigation exists. Read access follows existing tenant/project authorization.

## Rollout Guard

Feature flag: `operational_supervisor_read_only`, default **off**. #4688 adds its definition; #4689 gates scheduled analysis. Operators use the existing feature-flag administration surface. Disabling it stops new snapshots and analysis while retaining audit records. Cleanup requires #4691's evidence audit; it is not authorized by this planning issue.

## Acceptance

- The pilot creates only sanitized incident records and never changes delivery controls.
- Tests prove prohibited fields never reach the LLM and malformed output cannot mutate delivery state.
- Findings deduplicate by fingerprint with snapshot/prompt/model provenance.
- Authorized operators see scoped open incidents above live metrics and supervisor health.
- A disabled flag performs no snapshot, LLM call, or delivery mutation.

## Implementation tree and holds

#4687 is the P3 umbrella. P3 #4688 implements persistence/snapshot; #4689 implements `agent_harness` analysis and depends on #4688; #4690 implements dashboard/health and depends on #4688/#4689; #4691 is the terminal evidence audit and depends on all three. All remain under a planning hold until this RDR and LID artifacts are approved and merged. #4691 uses non-closing `Tracks #4687`; only a final umbrella audit may decide acceptance. External notifications were not filed because they are outside selected scope.

## Open decisions for review

- Confirm the two-healthy-snapshot resolution rule versus human-only resolution for first rollout.
- Set retention for sanitized snapshots and structured responses.
- Decide any future mitigation authorization matrix only in a future amendment.
