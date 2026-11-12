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
and audit events that are immutable for the account's lifetime. Account
teardown removes those tenant-scoped events through the account foreign-key
cascade; there is no independent update or delete path. `conservative` is the
default. An admission stores the posture signature plus the design, acceptance,
and evidence revisions it relied on; a later broadening never changes that
admission.

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
the shared read model for settings, Inbox, API, and MCP.
`Automation::DelegatedActionAdmission` is the shared write/admission contract
for queue, dequeue, retry, follow-up recording, closeout, and repair jobs. It
uses the effective-policy decision as a boundary input, so a disabled phase or
revoked continuation authority blocks the action and creates one focused
human decision. All calls record the same policy signature and evidence
references.

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

## Admission snapshot and revision boundaries

Every delegated admission persists one snapshot in the bounded authorization's
evidence: the delegation posture level and revision it relied on, the intent,
acceptance, and evidence revisions, the effective policy signature, the
admission phase, and the stop-before phase. The snapshot is written once and
is never rewritten by a later posture change, so the consent an admission
carried stays inspectable after the owner changes the project's posture.

The boundary recheck compares the current posture with the pinned snapshot
instead of comparing two opaque signatures:

| Current posture vs. admitted snapshot | Outcome |
| --- | --- |
| Same authority (a re-selection at the same level) | The admission keeps its admitted scope and continues. |
| Narrower authority (a rollback to `conservative`, a disabled guard, a paused expansion) | The next action is prevented and the admission snapshot, evidence, and audit history are preserved. |
| Broader authority (a new broader posture) | The broadened authority applies only to new admissions. The in-flight admission never gains it and stops until it is admitted again. |

The revisions an admission pinned stay the other half of the binding: intent,
acceptance, and evidence revisions must still be current at the boundary, so a
settlement that moved on cannot be executed under the old admission.

## Delegation rollback, hold, and recovery

The conservative rollback is the narrowing write path: selecting
`conservative` records the selection and the rollback in the immutable audit
history, blocks every future delegated boundary for the project, and routes
the project's in-flight delegated work to one focused Inbox decision each. It
never reinterprets or deletes the admission snapshots or evidence it stops.

An explicit delegation hold is a separate durable record scoped to the
project. It pauses the next delegated action without changing the posture or
any admission, and it is released by an authorized actor rather than by a
posture change. A held project keeps its posture selection and its evidence
while no delegated action may start.

Expiry, revocation, and the bounded stop are properties of the admitted
authorization, not of the posture. Each one prevents the next action, keeps
the authorization row, its snapshot, and the audit history, and routes one
focused decision that names the recovery:

| Stop | Reason | Recovery the decision names |
| --- | --- | --- |
| Authorization expired | `authorization_expired` | A new explicit authorization for the same lineage. |
| Authorization revoked | `authorization_revoked` | A new explicit authorization; revocation is not reversed by the work itself. |
| Posture rolled back to `conservative` | `posture_narrowed` | Re-admission under the current posture. |
| Posture broadened after admission | `posture_broadened` | Re-admission under the current posture; the in-flight admission keeps its own scope. |
| Explicit delegation hold | `delegation_hold` | Releasing the hold by an authorized actor. |
| The admitted action reached its stop-before phase | `bounded_stop` | Technical-stop recovery inside the admitted lineage; never a new lineage. |

Every recovery stays inside the admitted lineage: a stop may be recovered by
re-admitting, re-authorizing, releasing a hold, or by a technical recovery of
the same lineage. None of them opens new work, refreshes a stale review, or
extends the delegated scope.

## Rollback and measurement

The implementation is behind the existing `automation_phases` flag and a
default-off project `project_delegation` gate. Rolling back selects
`conservative`, preserves evidence/audit history, blocks future delegated
boundaries, and creates focused recovery requests. Metric events use the
tenant-scoped Inbox history ledger and snapshot posture, policy, intent,
acceptance, and evidence revisions. The pilot evaluator measures decision
volume/time, completion, reversals, and security/tenant/trust/evidence stop
signals. The separate expansion guard is default-off and permits broadening
only after the RDR-080 sample, observation, baseline, and threshold checks
pass. When expansion is enabled, posture resolution consumes that guard at the
admission boundary and falls back to `conservative` after a reversal or safety,
trust, tenant, or evidence stop. Issue lifecycle transitions, resolved human
decisions, and delegated-boundary stops write the metric ledger through their
production choke points; aggregation admits only the current posture/policy
authority and each subject's latest revision tuple.

The delegated boundary requires a canonical `security` assessment input before
expansion. No such producer currently supplies the expansion admission
snapshot, so its absence fails closed and records `security_breach` in the
pilot ledger. A future producer must supply an explicit current result; an
explicit failed assessment uses the same pause signal. This keeps expansion
disabled until security evidence is available rather than treating unavailable
evidence as healthy.

## Decisions & alternatives

| Decision | Rationale | Alternative rejected |
| --- | --- | --- |
| Compose one effective policy | Existing RDRs remain authoritative and every execution surface receives one answer. | A parallel approval/delegation evaluator would drift. |
| Snapshot policy and evidence at admission | An owner can change future posture without retroactively enlarging consent. | Re-evaluating an in-flight admission against a broader setting. |
| Focus a stop on one material delta | Settled intent should not be repeatedly re-litigated. | Reopen all questions for every downstream stop. |
| Permit recording a follow-up, not executing it | The finding must be recorded and linked, but the follow-up carries its own authority. | Rejecting the follow-up record, or letting the delegated posture run it. |
