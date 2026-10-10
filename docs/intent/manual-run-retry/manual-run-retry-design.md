---
parent: PAID
prefix: MANUAL-RUN-RETRY
---

# Low-Level Design: Manual Run Retry (Issue-less)

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers automatic retry of failed manual agent runs that carry no
> `issue_id` and no `source_pull_request_number` (#4222). The sibling
> `eager-queue-seeding` segment (EAGER-QUEUE-007) covers the equivalent
> backoff re-enqueue for issue-attached runs; this segment exists because
> every mechanism there is issue-driven and does nothing for an issue-less
> run.

## Purpose

`create_feature`, `create_issue`, `lid_planning`, and issue-less `create_pr`
runs have no issue or PR to anchor retry bookkeeping. A failed run of this
shape (most commonly transient runner/provider exhaustion at dispatch —
`iterations: 0`, no side effects) was previously terminal: nothing re-queued
it, no operator surface showed it, and a human had to notice it on the
agent runs page and re-trigger manually. Evidence (run 10616, run 10309)
showed the retry, once triggered, succeeded — the failure class is
transient, not a code-level problem the agent needs to fix.

## Where retry is armed

`Activities::MarkAgentRunFailedActivity#execute` is the funnel every
Temporal-driven run failure passes through. Its existing issue-driven branch
(`if agent_run.issue && agent_run.status.in?(AgentRun::FAILURE_STATUSES)`)
arms the issue-level auto-pick re-enqueue backoff (EAGER-QUEUE-007) and has
no effect when `agent_run.issue` is nil. `#schedule_manual_run_retry_if_eligible`
is the issue-less counterpart, called unconditionally after that branch:

```ruby
def manual_run_retry_eligible?(agent_run)
  agent_run.manual? &&
    agent_run.issue.nil? &&
    agent_run.source_pull_request_number.nil? &&
    agent_run.status.in?(AgentRun::FAILURE_STATUSES) &&
    !agent_run.recoverable_rate_limited? &&
    agent_run.project&.retry_failed_manual_runs? &&
    agent_run.no_observable_work?
end
```

`issue.nil? && source_pull_request_number.nil?` is sufficient to scope this
to exactly the four goals named above: `AgentRun#issue_goal_requires_issue`
requires an issue for `enhance_issue`/`analyze_issue`, and
`#review_goal_requires_pull_request` requires a PR for `review` — no other
goal can be issue-less and PR-less by validation.

## Why `recoverable_rate_limited?` is excluded

A `rate_limited` run with `rate_limited_until` present is already being
recovered in place by `StaleRunDetectorJob#recover_rate_limited_run`
(issue-agnostic — it does not check `issue_id`). Scheduling a second,
mint-a-new-row retry for the same run while that in-place recovery is
pending would race it and could produce two concurrent attempts at the same
work. This mirrors exactly why the issue-driven branch above keeps the
issue `in_progress` instead of `failed` for the same case.

## Partial-work safety: `AgentRun#no_observable_work?`

```ruby
def no_observable_work?
  iterations.to_i.zero? && pull_request_number.blank? && created_issue_number.blank?
end
```

A blind retry is only safe when nothing was produced yet. `create_issue`/
`create_feature` runs can create a GitHub issue or open a PR before a later
step fails (e.g. a post-publish verification gate); retrying those blindly
risks a duplicate issue or PR. `iterations == 0` plus no recorded
`pull_request_number`/`created_issue_number` precisely covers the
dispatch-exhaustion class this feature targets (runner/provider resolution
failed before any model turn ran) and excludes anything with partial work,
which is left terminally `failed` for an operator — consistent with issues #4212/#4221
deliberately treating Inbox visibility of such runs as a separate concern.

## No failure-class filtering

Any status in `AgentRun::FAILURE_STATUSES` is eligible (once the checks
above pass), not just runner-exhaustion-shaped errors. This mirrors
EAGER-QUEUE-007, which re-enqueues an issue after *any* `failed` state with
no error-message filtering: a deterministic failure (e.g. a validation
error) burns through the retry cap and then stays terminally failed, same
as it would for an issue-attached run.

## Retry-chain identity without an issue

There is no issue to hold "how many times has this logical work been
retried." `external_metadata` carries that bookkeeping instead, using two
keys defined on `AgentRun`:

- `AgentRun::MANUAL_RETRY_ATTEMPT_METADATA_KEY` (`"manual_retry_attempt"`) —
  the 1-indexed attempt number recorded on the *new* run minted by a retry.
  Absent (reads as `0` via `AgentRun#manual_retry_attempt`) on an original,
  non-retry run.
- `AgentRun::MANUAL_RETRY_PARENT_METADATA_KEY`
  (`"retried_from_agent_run_id"`) — the id of the run this one superseded,
  for traceability.

`MarkAgentRunFailedActivity` computes `attempt = agent_run.manual_retry_attempt + 1`
and declines to schedule once `attempt > AgentRun::MAX_MANUAL_RETRY_ATTEMPTS`
(3, matching the existing small-cap convention of
`RetryTimedOutIssueGoalJob::MAX_RETRIES` and
`AgentRun::MAX_RATE_LIMITED_REQUEUES`'s shape). The cap is enforced by the
scheduler before enqueuing and re-checked inside the job before minting a
new row, so a stale or duplicate job execution cannot exceed it.

## `RetryFailedManualRunJob`

Scheduled with `RetryFailedManualRunJob.set(wait: retry_delay(attempt)).perform_later(agent_run_id, attempt)`
— the same "delay the job that creates the follow-up work" shape as
`Issue#enqueue_self_if_became_auto_pick_eligible` →
`Issues::ReenqueueEligibleJob`. The delay is a small bounded exponential
curve (30s / 1m / 2m, capped at 5m), deliberately much flatter than
EAGER-QUEUE-007's `(n**4)+15` curve: the retry cap here is 3, not ~50, and
the target failure class (dispatch-time provider exhaustion) is expected to
clear within minutes, not hours.

`#perform(agent_run_id, attempt)`:

1. Re-checks eligibility under a row lock (`AgentRun.lock.find_by`) —
   state may have changed since scheduling (toggle flipped off, an operator
   intervened, the run was already retried).
2. Calls `agent_run.retry!` on the original — the same `"retried"` terminal
   status review-goal bookkeeping already uses to mark a superseded run, so
   dashboards and queries that already understand `"retried"` do not need a
   new status to special-case.
3. Mints a new `AgentRun` by whitelisting the fields that define "what to
    run" from the original — `project`, `initiating_user`, `runner`,
    `agent_type`, `custom_prompt`, `plan_doc_source`, `goal` — plus
    `external_metadata` merged with the retry-bookkeeping keys above. This
    mirrors `RetryTimedOutIssueGoalJob#perform`'s `AgentRun.create!` call,
    with two additions: `external_metadata` must be carried forward because
    `create_feature` derives its prompt from
    `external_metadata["feature_brief"]`
    (`AgentRun#has_prompt_source`) — a fresh empty hash would silently strip
    it — and `plan_doc_source` must be carried forward because a manually
    started `lid_planning` run can fail before
    `ensure_lid_planning_prompt!` persists `custom_prompt`, leaving
    `plan_doc_source` as the only record of the operator-selected design
    document. Execution-state columns (container, temporal workflow, PR/issue
    artifacts, timestamps) are intentionally not copied; they belong to the
    old run's attempt, not the new one.
4. Marking "retried" happens *before* the insert, in the same transaction,
   so the new row never collides with
   `idx_agent_runs_unique_active_lid_planning` (the partial unique index
   that treats `rate_limited`/`queued`/`running`/`paused` `lid_planning`
   runs as active per project).
5. Enqueues `ProcessRunQueueJob` (idempotent) so the new queued run is
   picked up promptly.

## Project-level toggle

`Project#retry_failed_manual_runs` (boolean, default `true`) gates
scheduling, exposed via `Project::AUTOMATION_SETTINGS` alongside the other
automation toggles (Auto-Pick, Auto-enhance, etc.) so it renders in the
project settings form and detail view with no additional view code.

## What this is not

- **Not a change to issue-attached retry behavior.** The existing
  `if agent_run.issue && ...` branch and EAGER-QUEUE-007 are untouched.
- **Not a change to `StaleRunDetectorJob`.** That job's scope (unfinished
  statuses, plus in-place `rate_limited` recovery) is unchanged; this
  feature explicitly defers to it for `recoverable_rate_limited?` runs.
- **Not an Inbox-visibility feature.** A run that exhausts its retry cap, or
  that has partial work and is never auto-retried, stays `failed` and
  invisible outside the agent runs page — see #4212/#4221 for that
  separate, deliberately out-of-scope discussion.
