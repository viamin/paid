# RDR-063: Operational Supervisor for Delivery Health

> Draft for normal design review. It authorizes planning and a
> disabled-by-default shadow rollout only; it does not authorize autonomous
> mitigation.

## Metadata

- **Date**: 2026-10-27
- **Status**: Draft
- **Type**: Operations + AI Safety + Automation
- **Priority**: P3
- **Related RDRs**: [RDR-011](RDR-011-observability.md), [RDR-023](RDR-023-automation-modularization-architecture.md), [RDR-047](RDR-047-work-category-queue-priority.md), [RDR-049](RDR-049-configuration-health-checks.md), [RDR-051](RDR-051-lid-aware-agent-runs.md), [RDR-054](RDR-054-prompt-assembly-service.md)
- **Related Intent**: [Operational Supervisor LLD](../intent/operational-supervisor/operational-supervisor-design.md), [EARS](../intent/operational-supervisor/operational-supervisor-specs.md), [arrow](../arrows/operational-supervisor.md)
- **Related Issues**: #4341 (planning); [#4708](https://github.com/viamin/paid/issues/4708) (epic); [#4709](https://github.com/viamin/paid/issues/4709), [#4710](https://github.com/viamin/paid/issues/4710), [#4711](https://github.com/viamin/paid/issues/4711), [#4712](https://github.com/viamin/paid/issues/4712), [#4713](https://github.com/viamin/paid/issues/4713), [#4714](https://github.com/viamin/paid/issues/4714)
- **Related Tests**: planned `OPERATIONAL-SUPERVISOR-001` through `-012`; no runtime supervisor exists.

## Problem and evidence

Paid has useful deterministic local protections but no account-level
delivery-health observer. Current primitives include `AgentRunAnomaly`,
`Notification` plus Inbox, `AgentRuns::DispatchCircuitBreaker`, auto-pick
configuration/gates, guardrails, and PR escalation recovery. They stop known
local failure modes; none builds a sanitized top-down view of whether work is
becoming merged pull requests economically.

No `OperationalSupervisor` implementation or prior implementation tree was
found. This is a planning gap, not evidence that autonomous mitigation is ready
to ship. The prior draft also left storage, authority, expiry, and metric
decisions unresolved.

## Decision

Build a bounded **Operational Supervisor** in two separate stages:

1. **Selected v1: disabled-by-default shadow observation.** Build a
   sanitized, account-scoped snapshot; use `agent_harness` to classify it via a
   strict schema; persist validated incidents; and show urgent findings and
   supervisor health. Its only automatic outcome is `open_incident_only`.
2. **Not selected:** any mitigation. A later RDR-063 amendment and shadow
   evidence must select every action before it may be enabled. #4713 is a hold,
   not action authority.

The LLM makes semantic pattern judgments. Rails owns aggregation, schema
validation, policy, authorization, and every state transition. Existing
guardrails and circuit breakers remain enforcement primitives.

## Hard safety boundary

The deterministic Rails snapshot builder is the only model input path. It may
contain opaque account/project/issue/PR/run IDs, Paid-UI-visible slugs, enum
states, bounded counts/rates/stage ages, token/cost totals, and pre-classified
guardrail, escalation, anomaly, and phase categories.

It MUST NOT contain issue/PR titles, bodies, comments, commit messages/diffs,
repository paths/content, agent prompts/output/logs/summaries, user names or
emails, credentials/secrets/tokens, raw provider responses, or raw exception
text. Later persistence must not reattach those fields. All calls use
`agent_harness`; the model receives no database, shell, tool, or action
credential.

## Architecture and selected boundaries

```text
OperationalSupervisorJob (guarded, account-scoped)
  -> Snapshot (deterministic allowlist + bounded rollups)
  -> Analyze (agent_harness, fixed prompt/schema)
  -> ValidateFindings (Rails)
  -> OperationalSupervisorIncident (sanitized audit record)
  -> Notification/Inbox projection + dashboard incident panel
```

### Incident storage

`OperationalSupervisorIncident` is the authoritative lifecycle record. It has
a stable fingerprint/version, account and permitted targets, sanitized
evidence, lifecycle status, timestamps, validated recommendation, action/audit
references, and model/prompt provenance. `Notification` is a projection for
badge/Inbox policy—not action or recovery truth. This reuses existing visible
operator surfaces without overloading a dismissible notification with durable
incident and future mitigation state.

### Snapshot and delivery-health metrics

One bounded snapshot is built per account window. It records metric version,
window, denominator, missing-data state, and freshness, and uses only a
mechanical ordering for top-N candidates. Initial facts are issue-to-PR and
PR-to-merge conversion, cost/tokens per merged PR, rework/follow-up and commit
counts, queue/lifecycle age, categorized failures, guardrail/escalation/anomaly
counts, starvation, and supervisor availability. A missing or too-small sample
is `insufficient_data`, never zero or healthy. Code may bound inputs and gate
safety; it must not hard-code a semantic quality judgment or health score.

### Findings, authority, mitigation expiry/recovery

V1 accepts only `open_incident_only`. Rails rejects malformed/unknown outputs,
targets absent from the snapshot, duplicate evidence, and unavailable actions;
invalid output makes a bounded supervisor-health observation and no mutation.
The scheduled job has system read authority only. Operator viewing and
acknowledgement/dismissal use account/project policy scope; model output never
grants authority.

Every future mitigation must be separately allowlisted, least-scoped,
row-locked/idempotent, current-state precondition-checked, explicitly
authorized, and audited before/after execution. It must expire at a recorded
time or deterministic recovery condition and record recovery. It must not
silently resume broad automation; recovery requires that action's explicitly
safe rule or a human decision. V1 has no mitigation to expire.

## Rollout guard, rollback, and cleanup

Implementation must introduce account setting `operational_supervisor_mode`
with default `off` and permitted initial value `shadow`. `shadow` allows only
observation/incident projection. No `mitigate` mode or implicit enablement is
authorized by this draft.

- **Enablement:** an authorized account operator explicitly enables `shadow`
  only after accepted design/LID code has merged.
- **Rollout:** fixture and staging snapshots, then a small volunteer cohort;
  monitor false positives, invalid output, latency, and incident volume.
- **Rollback:** set `off`; no job/model/projection runs. Incidents remain
  readable, marked with their final observation time, and are not fresh proof.
- **Cleanup:** retain only documented sanitized incident/audit records; expire
  snapshot/model-output artifacts by the retention decision; remove resolved
  projections without deleting necessary audit provenance.

## Measurable acceptance for selected scope

- Fixtures prove forbidden authored content, logs, prompts, exception text,
  credentials, and secrets reach neither prompt nor incident persistence.
- Snapshot values carry provenance, denominator, freshness, and
  insufficient-data state; top-N selection is deterministic and bounded.
- Unknown/invalid output cannot mutate scheduling, configuration, or an
  external system and produces a bounded health signal.
- Valid shadow findings deduplicate into a tenant-scoped incident with audited
  model/prompt identity and visible policy-scoped operator surface.
- `off` causes no supervisor work. `shadow` changes no auto-pick, follow-up,
  queue priority, project setting, or external service.
- Operators can distinguish last successful, failed, stale, unavailable, and
  empty supervisor evidence. External notifications are excluded.

## Implementation tree and holds

[#4708](https://github.com/viamin/paid/issues/4708) Tracks—not closes—this
planning work. Its P3-held children are:

1. [#4709](https://github.com/viamin/paid/issues/4709) incident/audit contract
   — depends on #4341.
2. [#4710](https://github.com/viamin/paid/issues/4710) sanitized snapshot and
   metrics — depends on #4341.
3. [#4711](https://github.com/viamin/paid/issues/4711) `agent_harness` analysis
   and validator — depends on #4709 and #4710.
4. [#4712](https://github.com/viamin/paid/issues/4712) shadow scheduler and
   surface — depends on #4709 and #4711.
5. [#4713](https://github.com/viamin/paid/issues/4713) separately approved
   mitigation evaluation — depends on #4712 and remains held.
6. [#4714](https://github.com/viamin/paid/issues/4714) final evidence audit —
   depends on #4712 and #4713, Tracks #4708 non-closingly, and may recommend
   closure only after verifying shipped evidence.

Every task records the #4341 design/LID merge hold or its downstream
equivalent. Filing/closing an issue is not implementation evidence.

## Explicit unresolved decisions for design review

1. Retention/access policy for sanitized snapshots, structured responses, and
   incident audit records.
2. Exact role and UI workflow for acknowledgement, dismissal, and future
   action authorization.
3. Metric windows, minimum denominators, and top-N caps; these are sampling
   parameters, not quality thresholds.
4. Shadow cohort size, success/noise criteria, and duration before proposing a
   mitigation amendment.
5. Whether a later action reuses escalation, auto-pick gates, or a narrow new
   control; no parallel pause flag may hide its recovery mechanism.

## Consequences

Paid gains a reviewable delivery-health observer without a second source of
operational truth or LLM mutation authority. It adds scheduled/model cost and a
health surface, so bounded snapshots, explicit missing-data handling, disabled
default, and evidence-based rollout are required. Broad mitigation and external
notifications remain deliberately out of scope pending review.
