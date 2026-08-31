---
parent: PAID
prefix: NO-OUTPUT-ISSUE
---

# Low-Level Design: No-Output Issue Handling

> Companion to the high-level design (`docs/high-level-design.md`). This LLD
> defines how issue-scoped runs that produce no PR/commit transition the issue
> into a human-actionable state without disappearing from operator view.

## Purpose

`HandleNoOutputIssueRunActivity` owns the last step of an issue-scoped run that
did not open a pull request. The state transition is consequential:

- `paid_state: "recommend_close"` removes the issue from the auto-pick queue.
- `paid_state: "needs_input"` parks the issue until a human answers.

In both cases the GitHub explanation comment is the only rationale a human sees
on the issue itself. A parked issue with neither that rationale nor a surfaced
error violates the HLD tenet "No silent stops."

## Outcome handling

For human-actionable no-output outcomes (`recommend_close` and `needs_input`),
the activity performs two duties:

1. Transition the issue into its Paid-side parked state and reconcile labels.
2. Ensure the missing-PR explanation is either visible on GitHub or durably
   surfaced as an execution problem on the agent run.

The state transition happens before the comment attempt, so comment-post
failures do not roll back the issue state. Instead the activity records the
failure on the `AgentRun` in two forms:

- `error_message` carries a concise user-visible summary for existing run and
  dashboard surfaces.
- `external_metadata["issue_explanation_comment_failure"]` stores structured
  details (`issue_state`, `marker`, `error`, timestamp) for durable inspection.

This keeps the consequential state change idempotent while satisfying the
visibility requirement when GitHub is unavailable or rejects the comment.

## Retry and deduplication

The activity remains safe to retry:

- Before posting, it checks recent issue comments for the marker corresponding
  to the parked state.
- If the marker is already present, it skips posting and clears any previously
  recorded comment-failure metadata for that run.
- If the post succeeds on a later retry, it also clears the recorded failure.

This preserves marker-based deduplication while allowing a previously surfaced
comment failure to self-heal once the human-visible rationale exists.
