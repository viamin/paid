# EARS Specs: Eager Queue Seeding

> Testable claims for eagerly seeding eligible issues into the auto-pick
> queue and rechecking that eligibility at dequeue time (RDR-032). Status
> markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r EAGER-QUEUE-001`).

## Single-issue seeding

- [x] **EAGER-QUEUE-001** — When an eligible issue is enqueued for an
  auto-pick-enabled project, the system SHALL create one queued automatic
  `AgentRun` (with a resolved agent type) via `find_or_create_by!` against
  the unique-active-run index, so concurrent enqueue attempts resolve to the
  same run rather than producing duplicates.
  *Code:* `Issues::EnqueueEligible#call`, `Issues::EnqueueEligible#blocking_runs`.
  *Test:* `spec/services/issues/enqueue_eligible_spec.rb`.

- [x] **EAGER-QUEUE-002** — When Auto-Pick is disabled for a project, the
  enqueue path SHALL create no new run, so stale sync or retry work cannot
  recreate queued Auto-Pick runs after the operator turns the feature off.
  *Code:* `Issues::EnqueueEligible#call` (auto_pick_enabled guard).
  *Test:* `spec/services/issues/enqueue_eligible_spec.rb`,
  `spec/models/project_spec.rb`.

## Bulk seeding

- [x] **EAGER-QUEUE-003** — When all currently-eligible issues for a project
  are seeded at once, the system SHALL iterate the eligible scope in batches
  and delegate to the single-issue path per issue (no bulk upsert), counting
  created, existing, and skipped runs for observability.
  *Code:* `Issues::BulkEnqueueEligible#call`,
  `Issues::BulkEnqueueEligible#each_eligible_issue`.
  *Test:* `spec/services/issues/bulk_enqueue_eligible_spec.rb`.

## Reactive seeding triggers

- [x] **EAGER-QUEUE-004** — The system SHALL seed eligible issues on issue
  lifecycle events rather than only on a scheduler tick: per-issue on an
  incremental GitHub sync, in bulk on a full sync or project import, in
  bulk when `auto_pick_enabled` is toggled on, and per-dependent when a
  blocking issue closes.
  *Code:* `FetchIssuesActivity#seed_eligible_issues`,
  `Project#seed_eligible_issues`, `Issue#enqueue_newly_unblocked_dependents`,
  `AutoPickQueueBackfillJob`, `AutoPickEligibilitySweepJob`.
  *Test:* `spec/temporal/activities/fetch_issues_activity_spec.rb`,
  `spec/models/project_spec.rb`, `spec/models/issue_spec.rb`.

## Dequeue-time eligibility recheck

- [x] **EAGER-QUEUE-005** — When the scheduler is about to claim a queued
  auto-pick run tied to an issue, the system SHALL re-check that issue's
  eligibility at dequeue time, and SHALL cancel the run (freeing its slot
  and removing it from the dashboard preview) when the issue is no longer
  eligible — skip label, `paid_state` skip, new blocking dependency,
  closed/completed, or paused — so the re-enqueue hooks can recreate it if
  the issue becomes eligible again.
  *Code:* `AgentRuns::RecheckIssueEligibility#call`,
  `AgentRuns::RecheckIssueEligibility#cancel_run`,
  `ProcessRunQueueJob` recheck invocation.
  *Test:* `spec/services/agent_runs/recheck_issue_eligibility_spec.rb`,
  `spec/jobs/process_run_queue_job_spec.rb`.

- [x] **EAGER-QUEUE-006** — The dequeue recheck SHALL apply only to
  eagerly-seeded auto-pick runs tied to an issue, and SHALL skip manual
  runs, runs with no issue, and `review` goals.
  *Code:* `AgentRuns::RecheckIssueEligibility#recheck_applicable?`.
  *Test:* `spec/services/agent_runs/recheck_issue_eligibility_spec.rb`.

## Failed-run re-enqueue backoff

- [x] **EAGER-QUEUE-007** — When a failed run makes an issue re-enter the
  queue, the system SHALL delay re-enqueue by Sidekiq's exponential curve
  `(n**4) + 15 + jitter` seconds (n = consecutive auto-pick failure count
  minus one), bounded so the count saturates at 50, so first retries are
  fast and persistently broken issues taper out rather than cycling forever.
  Re-enqueues following a non-`failed` state transition SHALL be immediate.
  *Code:* `Issue#auto_pick_reenqueue_delay`,
  `Issue#consecutive_auto_pick_failure_count`,
  `Issue#enqueue_self_if_became_auto_pick_eligible`,
  `Issues::ReenqueueEligibleJob`.
  *Test:* `spec/models/issue_spec.rb`.

## Capacity remains the single gate

- [x] **EAGER-QUEUE-008** — Eager seeding SHALL NOT itself limit concurrency
  or PR attention; `max_concurrent_runs` (with tenant guardrail) SHALL be
  the single capacity gate, and `AgentRun::QUEUE_ORDER` with its project/user
  fair-stride keys SHALL decide dispatch order unchanged by queue depth.
  *Code:* `ProcessRunQueueJob`, `AgentRun::QUEUE_ORDER`,
  `Capacity::RunAdmission`.
  *Test:* `spec/jobs/process_run_queue_job_spec.rb`.
