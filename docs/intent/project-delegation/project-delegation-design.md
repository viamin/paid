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
boundaries, and creates focused recovery requests. Metric events are revision
aware and measure decision volume/time, completion, and later reversals for
the bounded pilot defined by RDR-080.

### Pilot metrics

`ProjectDelegation::PilotMetric` is the durable per-project measurement row
for the RDR-080 pilot. One row records a posture cohort (`conservative`
baseline or `bounded_delivery` pilot) over an explicit window: human Inbox
decision count, median and p90 decision seconds, completed-issue count and
rate, and settled-decision reversal count and rate. `ProjectDelegation::
RecordPilotMetrics` is the single write path: it validates the measured
inputs (counts, decision-time samples, reversal events, reason-coded
exclusions), computes the aggregates, and upserts idempotently per project,
posture, and window start. Every row pins the `intent`, `acceptance`, and
`evidence` revisions it joined on, and every reversal event carries both its
settled and its reversing revision, so a metric can never silently attach to
a revision it did not measure.

### Expansion guard and pause

`ProjectDelegation::ExpansionGuard` answers one question for every
broadening surface: may delegation expand for this project? It fails closed.
Broadening stays disabled unless the `automation_phases` and
`project_delegation` guards both permit, no unresolved expansion pause
exists, and the recorded pilot evidence meets every RDR-080 threshold — at
least 30 completed issues and a 14-day review window, at least a 25%
reduction in Inbox decisions per completed issue versus the project's own
conservative baseline, no median decision-time increase, no more than a
5-percentage-point completion-rate decline, and no material reversal
attributable to delegated work. Missing or incomplete metric evidence
blocks with its own reason; it is never treated as passing.

`ProjectDelegation::PauseExpansion` records an unresolved
`ProjectDelegation::ExpansionPause` for a material reversal, a security,
tenant, or trust breach, or missing metric evidence. The pause captures the
effective posture before it, routes one focused blocking Inbox decision for
human review, and while unresolved the project's effective posture is
`conservative` and the guard blocks broadening. Resolving a pause is a human
decision recorded on the pause row.

## Decisions & alternatives

| Decision | Rationale | Alternative rejected |
| --- | --- | --- |
| Compose one effective policy | Existing RDRs remain authoritative and every execution surface receives one answer. | A parallel approval/delegation evaluator would drift. |
| Snapshot policy and evidence at admission | An owner can change future posture without retroactively enlarging consent. | Re-evaluating an in-flight admission against a broader setting. |
| Focus a stop on one material delta | Settled intent should not be repeatedly re-litigated. | Reopen all questions for every downstream stop. |
| Permit recording a follow-up, not executing it | The finding must be recorded and linked, but the follow-up carries its own authority. | Rejecting the follow-up record, or letting the delegated posture run it. |
