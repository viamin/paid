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

## What resets the stuck state

- A completed `create_pr` run **whose commit resolved the triggering condition**
  (a completed `create_pr` that pushed the current head while the head still has
  unresolved triggers — e.g. failing CI checks — does NOT reset the streak)
- A completed `review` run or any `review` run that posted a review
- A new PR head commit
- `issues.review_goal_retry_reset_at`
- `issues.operational_failure_reset_at`

### Total follow-up hard gate

In addition to the streak-based escalation, `pr_followup_count` is enforced as a
hard gate. Once a ready/escalated PR has queued `max_pr_followup_runs` total
follow-up runs, no additional `create_pr` runs are queued. Ready-phase PRs
escalate to the owner at that point; escalated PRs simply stop receiving
follow-ups. This prevents infinite CI-fixing loops where each completed run
resets the streak without actually resolving the triggering condition (#3271).

Phase transitions by themselves do not reset the streak. Removing the
`paid-escalated` label also does not clear failures anymore; dismissal just
returns the PR to `ready` or `restarted` and lets the next real progress signal
determine whether automation has recovered.

## How it is used

- Escalation/stuck handling now keys off the unified failure streak instead of separate draft-review, ready-followup, and review-goal retry failure regimes.
- Automatic `create_pr` and `review` runs therefore contribute to the same failure accounting model.
- Existing phase fields still describe workflow state, but they no longer create separate failure-counting regimes.

### Scan-confirmation gate (downtime-immune)

The stuck state must be **confirmed across scan cycles**, not by a wall-clock
window. Each scan that finds the PR escalation-eligible (failure streak at its
phase-appropriate limit, or the operational-failure breaker tripped) increments
`issues.stuck_confirmation_count`; a scan that finds the PR recovered resets it
to zero. Escalation only fires once the count reaches
`ScanPaidPrsActivity::REQUIRED_STUCK_CONFIRMATIONS`.

Because the counter only advances when a scan actually runs, an outage — during
which Paid is offline and produces no scans — can never push a PR into
escalation on its own. This replaces the previous 3-hour wall-clock window,
which ticked during downtime and drove false escalations after Paid came back
online.

## Straight Answer

- A PR is stuck when its unified automatic-run failure streak has reached the
  phase-appropriate limit and that stuck state has persisted across the required
  number of **scan cycles** (not wall-clock time).
- That stuck state clears when the PR makes meaningful progress or hits an
  explicit cycle boundary reset; manual escalation dismissal alone does not
  clear it.
