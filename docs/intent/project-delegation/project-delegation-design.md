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
An RDR-078 stop is a proposed per-lineage boundary, not a posture choice;
until its acceptance and implementation, the posture cannot create one.

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

## Accepted issue closure (#4868)

An acceptance audit may authorize automatic source-issue closure only when its
request captured the project's effective `bounded_delivery` policy with the
`evidence_gated_issue_closure` action and Merge phase enabled. The audit itself
remains report-only. After its run completes, a separate closeout attempt
compares the captured policy signature with current policy and reuses the
existing GitHub closeout boundary. A later posture change never grants closure
to an older audit. Conservative projects retain the human Inbox action.

The close attempt requires a current, fully satisfied criterion assessment with
at least one cited evidence item per criterion and a source-closure disposition;
no open prerequisite, human hold, scanner check,
native child, or active run may remain. It records the audit run, evidence
digest, policy revision, and an evidence-linked rationale with a system actor.
The existing closeout lease serializes concurrent attempts and reconciles a
confirmed GitHub close. A refused or failed attempt leaves the issue visible
with its existing Inbox recovery path. Upstream-managed and synthetic scanner
issues remain outside Paid's GitHub mutation authority.

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
repository checks, authorization lifecycle, assessment availability, and
explicit work-item holds. A mismatch creates a narrow Inbox request rather
than falling through to a project default. Existing actions may finish their
current atomic unit but cannot begin a new one after a failed recheck.

Actor policy, lineage, and the semantic scope, ambiguity,
conflicting-evidence, and material-risk conditions owned by the bounded-phase
reassessment design remain planned until that reassessment path lands.

## Rollback and measurement

The implementation is behind the existing `automation_phases` flag and a
default-off project `project_delegation` gate. The settings surface routes a
selection of `conservative` through an auditable revisioned rollback command
that requires an operator-supplied reason, preserves
evidence/audit history, blocks future delegated boundaries, and creates
focused recovery requests. Reaching the exclusive stop completes the
authorization with a retained audit event; expiry, revocation, and explicit
holds block the next action without deleting the admission snapshot. Metric events use the
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
| Close after a terminal audit, not inside it | The audit run must no longer be an active-run blocker, and GitHub I/O must remain outside the assessment transaction. | Closing from the audit activity before its run completes. |
