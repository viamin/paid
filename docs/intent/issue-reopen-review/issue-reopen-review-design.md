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

An operator resolves a reopen review only after validating whether the original
closure remains sufficient and whether work remains. The decision is bound to
the synchronized GitHub revision that was reviewed, records the authorized
actor and a non-blank reason in the account audit trail, and never clears an
unrelated hold. If work remains, the operator may use the existing supported
continuation only after the decision has been recorded; if no work remains,
the issue stays visible for the normal closeout path rather than being silently
completed.

## Manual-review recovery routing

The Inbox classifies a manual-review item from durable provenance before it
offers an action. A pending reopen-review reason requires the revision-bound
intent decision above. An unresolved local, deployment, or external dependency
shows its owner and remains held until the dependency resolver observes it
resolved. Enhancement stops retain the existing question-answer and enhancement
retry actions. Scanner recurrence retains its recorded scanner evidence and
recovery action. Reasons that cannot be attributed to one of those producers
remain visibly unknown and have no automatic recovery action.

Recovery inspects unfinished runs for the issue before it changes state. Any
queued or running work keeps the hold visible for explicit operator
reconciliation. This makes repeated submission idempotent and prevents a
recovery action from creating a second run or silently clearing a hold while
work is already pending.
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
