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
into either a merge decision or a blocker snapshot that records exactly which
signals failed and which later checks were not evaluated because an earlier
gate already failed.

Auto-merge diagnostics read from that persisted snapshot instead of
re-evaluating eligibility a second time. The PR scan writes the snapshot onto
the synced issue row alongside `last_pr_scan_at`, so UI and chat surfaces can
report the same blockers the merge path used without making fresh GitHub API
calls or re-implementing the policy.

Human-authored PRs take the stricter path. They require owner approval,
successful checks, mergeability, fresh reviews for the current head, no
outstanding blocking review feedback, and resolved dependencies before a merge
decision is emitted.

Bot-authored dependency PRs take the narrower trusted path. Dependabot-like PRs
may skip owner-approval and review-feedback gates, but they still require the
project to permit dependency auto-merge, a supported executor author, green
checks, mergeability, and resolved dependencies. Today the merge executor is
Dependabot-specific, so other trusted dependency-update bots may be scanned and
diagnosed but are not reported as auto-merge-ready.

Execution is incremental rather than umbrella-driven. The dedicated
`DependabotAutoMergeJob` evaluates candidate PRs, merges at most one green PR
per pass, labels/comment-tags successful merges, and treats expected merge
rejections as logged no-ops rather than crashes. App-backed projects that have
a PAT push fallback configured reuse that fallback when a Dependabot merge is
rejected for a missing workflow permission. Terminal workflow-permission
failures reuse the PR row's merge-permission cooldown so Paid does not retry
the same permanent failure every poll cycle.

Auto-merge diagnostics are persisted as sanitized product data. Each merge
path appends an `AutoMergeAttempt` row for meaningful outcomes (merge, skip,
blocker, failure) so the UI, support workflows, and chat agents can explain
what happened without raw logs, tokens, webhook secrets, or stack traces.
Attempt rows are tenant-scoped through PostgreSQL row-level security keyed on
`projects.account_id`, so access follows project visibility.

## What this is not

- **Not a blanket bypass of human control.** Projects must opt in through
  `auto_merge_mode`; `off` remains the default.
- **Not a rebase of PR #950.** RDR-022's decision was to preserve the shipped
  behavior via focused incremental changes, not to revive the stale umbrella
  branch.
- **Not a trust grant for arbitrary bots.** The simplified path is limited to
  dependency-update bots the project explicitly supports.
