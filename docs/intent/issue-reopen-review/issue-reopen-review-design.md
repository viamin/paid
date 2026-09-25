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
auto-pick eligibility remains state-neutral; completion remains gated until
the review is resolved.

An operator resumes the issue from manual review only after validating whether
the original intent remains valid and whether new work is required. This moves
the issue back into active work through the existing manual-review workflow.
Automated completion activities re-check this gate immediately before changing
an issue to `completed`, so an in-flight run cannot overwrite it after sync.

## Chat-tool policy

The chat `edit_issue` tool requires both its existing write confirmation and an
explicit `reopen_review_confirmed` acknowledgement before it can reopen a
locally known closed issue. While the synchronized reopen review is pending,
the tool refuses a close transition. These checks make an agent's confirmation
intentional and prevent it from immediately undoing the gate it triggered.
