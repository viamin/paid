---
parent: PAID
prefix: EAGER-QUEUE
---

# Low-Level Design: Eager Queue Seeding

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers how eligible issues become queued automatic runs (RDR-032)
> and the dequeue-time recheck that keeps the eagerly-seeded queue honest.
> The sibling `auto-pick-queue` segment covers the toggle lifecycle (enable /
> disable → cancel queued runs).

## Purpose

The dashboard queue preview was empty even when many issues were ready,
because auto-pick seeded conservatively — at most one run per project per
tick, gated by a PR-attention limit. Eager seeding flips that: create a
queued `AgentRun` for every eligible issue the moment it becomes eligible,
and let the scheduler decide what to *start*. This makes the queue preview
reflect the real backlog and makes `max_concurrent_runs` the single capacity
gate.

## Seeding services

- **`Issues::EnqueueEligible`** — the single-issue seeding path. It re-checks
  the issue against `DefaultCandidateSource.eligible_scope`, resolves the
  intended agent type, and `find_or_create_by!`s a queued automatic run
  against the unique-active-run index (`idx_agent_runs_unique_active_issue`),
  rescuing `RecordNotUnique` to return the existing run on a race. It still
  respects the canonical `auto_pick_enabled` switch and
  `Issues::AutoPickProjectGate` at call time so stale sync/retry work cannot
  recreate queued runs after the operator turns the feature off.
- **`Issues::BulkEnqueueEligible`** — iterates the eligible scope in batches
  (`find_each`) and delegates to `EnqueueEligible` per issue. No bulk SQL
  upsert; correctness and auditability over throughput.

## Seeding triggers (reactive, not tick-based)

Seeding happens on issue-lifecycle events, not on a cron tick:

| Event | Path |
|---|---|
| Issue synced from GitHub (incremental) | `FetchIssuesActivity#seed_eligible_issues` → `EnqueueEligible` per issue |
| Full issue sync / project import | `FetchIssuesActivity` → `BulkEnqueueEligible`; `Project` import + `AutoPickQueueBackfillJob` |
| `auto_pick_enabled` toggled on | `Project#seed_eligible_issues` (`after_update_commit`) → `BulkEnqueueEligible` |
| Blocking issue closed | `Issue#enqueue_newly_unblocked_dependents` → `EnqueueEligible` per dependent |
| Periodic eligibility sweep | `AutoPickEligibilitySweepJob` → `BulkEnqueueEligible` |

The old one-run-per-project-per-tick `seed_auto_pick_queue` and the
PR-attention seeding limit (`max_auto_pick_open_prs` /
`deferred_by_pr_attention_limit?`) were removed: `max_concurrent_runs` is
the single concurrency control, and `AgentRun::QUEUE_ORDER` (with its
project/user fair-stride keys) decides dispatch order.

## Dequeue-time eligibility recheck

An issue can lose eligibility between seeding and the scheduler claiming the
run — a skip label added, `paid_state` entering a skip state, a new blocking
dependency, the issue closed/completed, or the scheduler paused.
`AgentRuns::RecheckIssueEligibility` re-checks only eagerly-seeded auto-pick
runs tied to an issue (manual runs, no-issue runs, and `review` goals are
excluded) at dequeue time via `DefaultCandidateSource.eligible_for_dequeue?`.
If the issue is no longer eligible it cancels the still-queued,
unclaimed run under a row lock (so a run claimed mid-check is not marked
cancelled), and the re-enqueue hooks re-seed it when it becomes eligible
again. `ProcessRunQueueJob` runs this recheck before capacity/Docker work so
ineligible runs do not consume expensive admission.

## Failed-run re-enqueue backoff

When a run finishes in `failed` state, the issue re-enters the queue via
`Issue#enqueue_self_if_became_auto_pick_eligible` →
`Issues::ReenqueueEligibleJob`. The wait uses Sidekiq's exponential backoff
curve (`Issue#auto_pick_reenqueue_delay`), with the retry attempt `n` taken
as the consecutive auto-pick failure count minus one (floored at zero):

```ruby
delay = (n**4) + 15 + (rand(10) * (n + 1))
```

First retries are nearly free (sub-minute), the curve keeps growing past the
old 4-hour ceiling, and `consecutive_auto_pick_failure_count` is bounded at
50 so the maximum delay saturates around ~72 days. State transitions that
are not `failed` (e.g. `analyzed → new`) re-enqueue immediately with no
delay.

## Duplicate-PR prevention (#3432)

`DefaultCandidateSource.eligible_scope` excludes an issue whose most recent
completed `create_pr` run already recorded `pull_request_number`, unless the
local, synced PR `Issue` row proves that PR closed without merging. This
covers two related situations:

- **Synced open PR** — `Issue.open_pull_request_parent_issue_ids` already
  excludes issues with a synced, open, `parent_issue_id`-linked PR row.
- **Unsynced or not-yet-linked PR** — `pull_request_number` is written
  atomically with the run's terminal `status` (`AgentRun#complete!`), but the
  local PR `Issue` row (and its `parent_issue_id` linkage) is written later
  by GitHub sync. `unsynced_pr_produced_issue_ids` closes that gap by
  excluding the issue directly from `AgentRun` state, bounded by
  `PR_SYNC_GRACE_PERIOD` (1 hour) so a PR row that never syncs — deleted
  branch, stale/wrong recorded PR number, sync backlog — does not strand the
  issue forever. This exclusion applies inside `base_scope`, so it protects
  every `paid_state` branch of `eligible_scope`, not only the
  `paid_state: "completed"` recovery branch — closing a race where
  `StaleRunDetectorJob#recover_orphaned_in_progress_issues` (or any other
  path) resets `paid_state` back to a pre-completion value after a PR was
  already opened.

A synced, closed-unmerged PR row always lifts the exclusion immediately
(no need to wait out the grace window), so legitimate replacement runs after
an abandoned or rejected PR are not delayed.

## Fair-stride impact

None. `QUEUE_ORDER` already sorts by project and user in-flight counts ahead
of queue priority, so eager seeding adds queued rows per project without
changing which runs the scheduler starts. A project with many queued issues
still only gets its fair share of concurrent slots; the dashboard preview
simply shows the full backlog.

## What this is not

- **Not a capacity control.** Eager seeding creates runs; it does not start
  them. `max_concurrent_runs` + `Capacity::RunAdmission` decide what runs.
- **Not strict-priority ordering.** See `queue-priority-tiers` and
  `account-queue-fairness` for how queued runs are ordered and whether an
  account opts out of fair-share.
- **Not focus scoping.** See `focused-agent-runs`; eager seeding is
  orthogonal to what problem a run targets.
