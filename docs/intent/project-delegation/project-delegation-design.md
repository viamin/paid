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

Each boundary rechecks current revisions, posture signature, explicit holds,
lineage, tenant/actor authorization, trust, budget, repository checks, and
assessment availability. A mismatch creates a narrow Inbox request rather than
falling through to a project default. Existing actions may finish their current
atomic unit but cannot begin a new one after a failed recheck.

## Rollback and measurement

The implementation is behind the existing `automation_phases` flag and a
default-off project `project_delegation` gate. Rolling back selects
`conservative`, preserves evidence/audit history, blocks future delegated
boundaries, and creates focused recovery requests. Metric events are revision
aware and measure decision volume/time, completion, and later reversals for
the bounded pilot defined by RDR-080.

## Decisions & alternatives

| Decision | Rationale | Alternative rejected |
| --- | --- | --- |
| Compose one effective policy | Existing RDRs remain authoritative and every execution surface receives one answer. | A parallel approval/delegation evaluator would drift. |
| Snapshot policy and evidence at admission | An owner can change future posture without retroactively enlarging consent. | Re-evaluating an in-flight admission against a broader setting. |
| Focus a stop on one material delta | Settled intent should not be repeatedly re-litigated. | Reopen all questions for every downstream stop. |
| Permit recording a follow-up, not executing it | The finding must be recorded and linked, but the follow-up carries its own authority. | Rejecting the follow-up record, or letting the delegated posture run it. |
