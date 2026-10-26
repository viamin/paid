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

An operator records an immutable, revision-bound validation decision and reason
before continuing a reopened issue. The decision is bound to the synchronized
GitHub revision, names the original closure and remaining scope review, and is
audited with its authorized actor. Only then may the Inbox offer the existing
manual analysis continuation. A stale revision must be refreshed instead of
being silently accepted.
Automated completion activities re-check this gate immediately before changing
an issue to `completed`, so an in-flight run cannot overwrite it after sync.

## Cause-specific Inbox recovery

`ManualReviews::Recovery` classifies a manual-review entry from durable
provenance, not from the free-form display reason. Pending reopen review needs
the revision-bound decision; real unresolved dependencies remain waits;
scanner-confirmed recurrences retain scanner recovery; enhancement-originated
stops retain their question forms and enhancement retry. An entry with no
recognized provenance stays visibly unknown and is not cleared by a generic
retry. Before continuation, the same service reports queued or running work so
the operator reuses or reconciles it rather than creating a competing run.

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
