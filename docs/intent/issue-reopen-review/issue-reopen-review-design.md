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

The manual-review entry classifies the gate from persisted provenance rather
than treating every parked issue as an enhancement failure. For a reopen gate,
it shows the prior closure context and the recorded reopen reason. An operator
resolves the gate only by recording a non-blank intent-validation reason bound
to the issue's current GitHub revision and choosing whether the issue needs
implementation or a fresh analysis. The decision is retained in the account
audit trail. A changed GitHub revision invalidates a stale form submission.

Resolution inspects every unfinished run for the issue while holding the issue
lock. Compatible queued or running work is reused and reported; incompatible
work keeps the gate visible for reconciliation. The action never creates a
second run and never silently clears the gate beside incompatible work.
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
