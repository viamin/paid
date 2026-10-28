---
parent: PAID
prefix: ISSUE-REOPEN-REVIEW
---

# Low-Level Design: Issue Reopen Review

## Purpose

A GitHub issue can be reopened by a chat tool or any other external actor after
Paid has completed or recommended closing it. That transition invalidates the
previous completion decision: the current intent and the original resolution
must be reviewed before Paid can treat the issue as complete again.

## Reopen gate

`Issues::UpsertFromGithub` is the single synchronization boundary for GitHub
issue state. When it observes a persisted non-PR issue transition from `closed`
to `open`, it places the issue in `manual_review` with the dedicated reopen
review reason. The Inbox exposes this state to an operator, and ordinary
automatic selection remains state-neutral; completion remains gated until the
review is resolved.

An operator resolves reopen review only after validating the original closure,
the current GitHub revision, and the remaining scope. The resolution records
the authorized actor, decision, reason, and revision in the account audit
trail. A decision that the closure remains valid records the review without
starting work; a decision that scope remains queues the existing supported
continuation only after the current review has been resolved. The continuation
never treats a reopen acknowledgement as a dependency waiver or as evidence
that an unrelated queued run is compatible.

## Cause-specific manual-review recovery

`ManualReviews::Recovery` classifies a manual-review item from durable,
structural provenance rather than interpreting the free-text review reason.
The dedicated reopen gate, unresolved `IssueDependency` readiness checks,
scanner remediation-attempt state, preserved enhancement questions, and the
latest enhancement run select their respective existing recovery action. An
unrecognized combination remains visibly unknown and offers no state-clearing
action.

Recovery first inspects unfinished work for the issue. A compatible run is
reused and shown to the operator; an incompatible queued or running run keeps
the hold visible for explicit reconciliation. Dependency recovery names and
links the owner dependency and relies on the existing dependency-resolution
path to reevaluate readiness. Scanner recurrence offers the existing
implementation continuation; retryable scanner evidence remains a wait. The
existing enhancement retry and question-answer paths remain available only for
enhancement provenance.
Automated completion activities re-check this gate immediately before changing
an issue to `completed`, so an in-flight run cannot overwrite it after sync.

## Chat-tool policy

The chat `edit_issue` tool directs callers to `create_issue` for new work
related to a closed issue. Reopening is an exception: the tool consults GitHub's
current state before it permits an open transition, so a stale or missing local
mirror cannot bypass the guard. A caller authorized to manage issues must
provide the normal write confirmation, an explicit
`reopen_review_confirmed` acknowledgement, and a non-blank `reopen_reason`.
The tool records the authenticated Paid user, timestamp, and reason on the
issue and in the account audit trail, then explicitly places it in reopen
review even when the pre-update local state was stale. While the synchronized
reopen review is pending, the tool refuses a close transition. These checks
make an agent's confirmation intentional and prevent it from immediately
undoing the gate it triggered.
