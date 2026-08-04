---
parent: PAID
prefix: AUTO-MERGE
---

# Low-Level Design: Auto-Merge Strategy

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment records the shipped auto-merge policy after RDR-022 closed the large
> umbrella branch in favor of incremental delivery.

## Purpose

Paid lets project owners delegate the final merge decision under a narrow,
revocable policy instead of requiring a manual click for every pull request.
The current implementation splits that policy into:

- strategy evaluation for human-authored and bot-authored PRs
- a Dependabot-specific execution path for dependency updates
- project configuration that keeps auto-merge owner-controlled

This segment captures the shipped behavior rather than the abandoned umbrella
PR strategy discussed in RDR-022.

## Shipped behavior

The core strategy is policy-only. Upstream scan layers gather signals about
approvals, CI, mergeability, stale reviews, review feedback, and dependency
resolution, then `Automation::Strategies::AutoMerge` converts those signals
into either a merge decision or a noop.

Human-authored PRs take the stricter path. They require owner approval,
successful checks, mergeability, fresh reviews for the current head, no
outstanding blocking review feedback, and resolved dependencies before a merge
decision is emitted.

Bot-authored dependency PRs take the narrower trusted path. Dependabot-like PRs
may skip owner-approval and review-feedback gates, but they still require the
project to permit dependency auto-merge, green checks, mergeability, and
resolved dependencies.

Execution is incremental rather than umbrella-driven. The dedicated
`DependabotAutoMergeJob` evaluates candidate PRs, merges at most one green PR
per pass, labels/comment-tags successful merges, and treats expected merge
rejections as logged no-ops rather than crashes.

## What this is not

- **Not a blanket bypass of human control.** Projects must opt in through
  `auto_merge_mode`; `off` remains the default.
- **Not a rebase of PR #950.** RDR-022's decision was to preserve the shipped
  behavior via focused incremental changes, not to revive the stale umbrella
  branch.
- **Not a trust grant for arbitrary bots.** The simplified path is limited to
  dependency-update bots the project explicitly supports.
