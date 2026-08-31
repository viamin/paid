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
did not open a pull request. The outcome transition is consequential:

- `paid_state: "recommend_close"` removes the issue from the auto-pick queue.
- `paid_state: "needs_input"` parks the issue until a human answers.
- `blocked_on_gap` files a follow-up issue, records an explicit dependency on
  that issue in the parent, and returns the parent to `paid_state: "new"` so
  normal dependency gating controls re-eligibility.

For parked outcomes, the GitHub explanation comment is the only rationale a
human sees on the issue itself. For `blocked_on_gap`, the created follow-up
issue and the parent's explicit dependency declaration become the durable
operator-visible rationale. A stopped issue with neither visible rationale nor a
surfaced error violates the HLD tenet "No silent stops."

## Outcome handling

For human-actionable parked outcomes (`recommend_close` and `needs_input`), the
activity performs two duties:

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

## Follow-up gap signaling

When an issue-scoped run concludes that the parent issue is blocked on missing
work rather than obsolete, the agent may emit one same-repo follow-up plan in
its output using HTML comment markers:

```markdown
<!-- followup-title: Title for the new issue -->
<!-- followup-body-start -->
...markdown body for the follow-up issue...
<!-- followup-body-end -->
```

When both markers are present with non-blank content, the activity classifies
the run as `blocked_on_gap` instead of `recommend_close`. It then:

1. Creates or reuses one open same-project follow-up issue keyed by the
   truncated follow-up title.
2. Updates the parent issue body with an explicit dependency line recognized by
   Paid's dependency parser (`Depends on #N`, or the project-resolved
   equivalent).
3. Persists the dependency locally before committing the parent back to
   `paid_state: "new"` so eligibility callbacks see the new dependency, not a
   briefly-unblocked parent.

The parent is therefore removed from the queue by existing dependency semantics,
not by a second parking concept. When the follow-up closes, the existing
dependency-unblock path makes the parent eligible again without a new unpark
mechanism.

## Retry and deduplication

The activity remains safe to retry:

- Before posting, it checks recent issue comments for the marker corresponding
  to the parked state.
- If the marker is already present, it skips posting and clears any previously
  recorded comment-failure metadata for that run.
- If the post succeeds on a later retry, it also clears the recorded failure.

For `blocked_on_gap`, retries must also remain side-effect safe:

- The follow-up channel is capped at one issue per run; extra marker blocks are
  ignored.
- Before filing, the activity checks for an existing open same-project issue
  with the same truncated title and reuses it instead of creating a duplicate.
- Before mutating the parent body, it checks whether the dependency line is
  already present and avoids appending it twice. When the parent already has a
  dependency section — in either the tight `## Dependencies\n- #N` form the
  dependency parser reads by default or a blank-line-separated form — the new
  entry is merged into that section instead of adding a second heading.
- Every created or reused follow-up is recorded in the account audit trail with
  the parent issue, child issue, and agent run identifiers.

This preserves marker-based deduplication while allowing a previously surfaced
comment failure to self-heal once the human-visible rationale exists.
