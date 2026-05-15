# Unified PR Failure/Progress Model

Automatic PR retries now use one PR-level progress model for both `create_pr` and `review` runs.

## What is counted

- `consecutive_unsuccessful_automatic_runs`
  - Derived from automatic `create_pr` and `review` runs for the PR.
  - The streak is phase-agnostic: draft, restarted, ready, and escalated all share the same counter.
- `consecutive_operational_failures`
  - The operational-failure subset of that same streak.
- `last_meaningful_progress_at`
  - The last time the PR made progress that should clear the failure streak.
  - Successful manual PR runs also count as progress, even though only automatic runs contribute to the failure streak itself.

## What resets the streak

- A completed `create_pr` run
- A completed `review` run or any `review` run that posted a review
- A new PR head commit
- `issues.review_goal_retry_reset_at`
- `issues.operational_failure_reset_at`

Phase transitions by themselves do not reset the streak.

## How it is used

- Escalation/stuck handling now keys off the unified failure streak instead of separate draft-review, ready-followup, and review-goal retry failure regimes.
- Automatic `create_pr` and `review` runs therefore contribute to the same failure accounting model.
- Existing phase fields still describe workflow state, but they no longer create separate failure-counting regimes.
