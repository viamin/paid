---
parent: PAID
prefix: PROJECT-DELEGATION
---

# Low-Level Design: Project Delegation After Settled Intent

Implements accepted [RDR-080](../../rdrs/RDR-080-project-delegation-after-settled-intent.md).

## Boundary

`ProjectDelegation` defines a project-scoped posture after intent has been
settled. It does not own feature approval, confidence assessment, phase
selection, continuation grants, bounded stops, review freshness, or repository
controls. It supplies one normalized input to `Automation::EffectivePolicy`.

The durable posture record has project/account scope, an authorized actor,
selected level, policy revision/signature, enabled action classes, timestamps,
and immutable audit events. `conservative` is the default. An admission stores
the posture signature plus the design, acceptance, and evidence revisions it
relied on; a later broadening never changes that admission.

## Checkpoint and action plan

`ProjectDelegation::IntentCheckpoint::Plan` groups related material questions
and returns the recommendation, alternatives, consequences, evidence,
affected scope, and proposed revision. A human settlement produces immutable
answers linked to the design/acceptance revision. `ActionPlan` then resolves a
requested downstream action against those revisions and returns permit, block,
or a focused decision request. It allows only explicit technical choices,
one deduplicated follow-up record, classified technical recovery,
evidence-gated closeout, and bounded cycle repair.

`ActionPlan` answers whether a decision class is delegated or needs a human; it
never supplies execution authority. That stays with the RDR-077 phase policy
and the RDR-078 bounded authorization for the admitted lineage.

Recording a follow-up permits the finding, affected scope, evidence, owner,
and completion dependency that RDR-071 already requires, and nothing more. The
follow-up stays a separate work item with its own admission, policy snapshot,
and rechecks, so the delegated posture never executes it, never folds it into
the delegated scope, and never opens a new lineage for the delegated work.

Recovery stays inside the admitted lineage too. A remediation that needs its
own work item is recorded as a follow-up or routed to a human decision.

## Policy and surface parity

`Automation::EffectivePolicy` composes intent/readiness, phase policy,
continuation/bounded authorization, project delegation, and existing controls
in that order without copying their rules. `ProjectDelegation::Projection` is
the shared read model for settings, Inbox, API, and MCP. `ActionPlan` is the
shared write/admission contract for queue, dequeue, retry, follow-up
recording, closeout, and repair jobs. All calls record the same policy
signature and evidence references.

The initial boundary-recheck slice rechecks current revisions, posture
signature, applicable phase and bounded-stop policy, tenant, trust, budget,
repository checks, authorization lifecycle, and assessment availability. A
mismatch creates a narrow Inbox request rather than falling through to a
project default. Existing actions may finish their current atomic unit but
cannot begin a new one after a failed recheck.

The full boundary will additionally recheck explicit holds, actor policy,
lineage, and the semantic scope, ambiguity, conflicting-evidence, and
material-risk conditions owned by the bounded-phase reassessment design. Those
conditions remain planned until that reassessment path lands.

## Rollback and measurement

The implementation is behind the existing `automation_phases` flag and a
default-off project `project_delegation` gate. Rolling back selects
`conservative`, preserves evidence/audit history, blocks future delegated
boundaries, and creates focused recovery requests.

`ProjectDelegation::PilotEnrollment` is the explicit, per-project pilot
opt-in: at most five active enrollments platform-wide, each pinning the
project's own conservative baseline captured from recorded history
(`ProjectDelegation::PilotMetrics::Baseline`). `PilotMetricEvent` is the
append-only, revision-stamped ledger: human Inbox decisions with decision
time, admitted and completed issues, settled decisions later reversed,
security/tenant/trust breaches, and missing-evidence downgrades, each with
reason-coded exclusions. `ProjectDelegation::RecordPilotMetric` captures
events idempotently at the existing boundaries — bounded-action admission,
Inbox decision resolution, focused-decision reversal, and issue completion —
and a required revision it cannot resolve becomes an `evidence_missing`
event that pauses expansion rather than an unattributed metric.

`ProjectDelegation::ExpansionGuard` is the one broadening decision service:
broadening is disabled by default and permitted only after the RDR-080 review
window (at least 30 completed issues and 14 days) and only when every
enrolled project meets all thresholds against its own baseline — Inbox
decisions per completed issue down at least 25%, median decision time not
increased, completion rate down no more than 5 percentage points, and no
material reversal attributable to delegated work. A material reversal, a
security/tenant/trust breach, or missing metric evidence pauses expansion
through `ProjectDelegation::PauseExpansion`, which returns the affected
project to `conservative` (its enrollment pauses) and routes one focused
Inbox decision for the required human review.

## Pilot metrics and expansion guard

RDR-080's measurement section is implemented by the pilot recorder and the
expansion guard. `ProjectDelegation::EnrollPilotProject` opts a project into
the `bounded_delivery` pilot (at most five concurrently active enrollments)
and captures the project's own conservative baseline in the same transaction:
one `DelegationPilotMetricSnapshot` with posture `conservative_baseline` over
the lookback window ending at enrollment. `DelegationPilotMetricsSweepJob`
records a cumulative `bounded_delivery` snapshot per active enrollment daily
and then consults the guard.

A snapshot joins, for one project and window: human Inbox decisions
(`blocking` notifications on the project or its issues that a human resolved
or dismissed; automatic reconciliation releases are excluded with the
`auto_released` reason code), completed issues (`paid_state` reached
`completed`), admitted issues (distinct issues with a run created in the
window), and settled completions later reversed (the existing reopen-review
parking). Every snapshot pins the intent revisions of the joined work items
(`PartialCloseouts::Assessment.intent_revision_for`), so joins are revision
aware and later comparisons can prove which revisions produced the numbers.

`ProjectDelegation::ExpansionGuard` is the one decision service for
broadening: broadening is disabled by default, requires both rollout guards
(`automation_phases` and the named default-off `project_delegation` flag), an
active enrollment, complete baseline and pilot evidence, and every RDR-080
threshold — at least 30 completed issues and 14 days in the pilot, at least a
25% reduction in Inbox decisions per completed issue versus baseline, no
median-decision-time increase, at most a 5 percentage-point completion-rate
decline, and no reversal attributable to delegated work.

A material delegated reversal, a security/tenant/trust breach, or missing
metric evidence pauses expansion through `ProjectDelegation::PauseExpansion`:
the enrollment is parked `paused` with its reason and evidence, the project
is back at the `conservative` default, an account activity event is recorded,
and one blocking Inbox decision routes the pause for human review. Pause
preserves every snapshot and audit record; a human restores the pilot through
`ProjectDelegation::ResumePilotEnrollment`, which records the reviewer.

## Decisions & alternatives

| Decision | Rationale | Alternative rejected |
| --- | --- | --- |
| Compose one effective policy | Existing RDRs remain authoritative and every execution surface receives one answer. | A parallel approval/delegation evaluator would drift. |
| Snapshot policy and evidence at admission | An owner can change future posture without retroactively enlarging consent. | Re-evaluating an in-flight admission against a broader setting. |
| Focus a stop on one material delta | Settled intent should not be repeatedly re-litigated. | Reopen all questions for every downstream stop. |
| Permit recording a follow-up, not executing it | The finding must be recorded and linked, but the follow-up carries its own authority. | Rejecting the follow-up record, or letting the delegated posture run it. |
| Broadening behind one default-disabled guard | RDR-080 requires evidence before any default change, so one service must own the threshold decision every surface asks. | Enabling broader defaults at pilot enrollment, or per-surface threshold checks. |
| Ledger events instead of on-demand recomputation | Pilot metrics must be revision-aware and attributable, so facts are stamped when they happen; a recompute cannot recover the revision a decision was made against. | Deriving pilot metrics from current state at review time. |
| Persist metric snapshots, not read-time derivation | Broadening needs durable, inspectable evidence, and missing evidence must itself pause expansion. | Computing pilot metrics on demand, where a failed computation leaves no pause record. |
