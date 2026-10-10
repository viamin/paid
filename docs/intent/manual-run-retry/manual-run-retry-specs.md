# EARS Specs: Manual Run Retry (Issue-less)

> Testable claims for automatically retrying a failed manual agent run that
> carries no `issue_id` and no `source_pull_request_number` (#4222). Status
> markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r MANUAL-RUN-RETRY-001`).

## Scheduling

- [x] **MANUAL-RUN-RETRY-001** — When a manually-triggered agent run with no
  `issue_id` and no `source_pull_request_number` reaches a terminal status in
  `AgentRun::FAILURE_STATUSES` through `MarkAgentRunFailedActivity`, and the
  owning project has `retry_failed_manual_runs` enabled, the system SHALL
  schedule `RetryFailedManualRunJob` with a bounded exponential backoff delay
  (30s / 1m / 2m, capped at 5m) so the failure is retried automatically
  without human action, mirroring the issue-driven re-enqueue
  (EAGER-QUEUE-007) that has no effect on an issue-less run.
  *Code:* `Activities::MarkAgentRunFailedActivity#schedule_manual_run_retry_if_eligible`,
  `RetryFailedManualRunJob.retry_delay`.
  *Test:* `spec/temporal/activities/mark_agent_run_failed_activity_spec.rb`,
  `spec/jobs/retry_failed_manual_run_job_spec.rb`.

- [x] **MANUAL-RUN-RETRY-002** — The scheduling check SHALL NOT fire for a
  run that is attached to an issue, attached to a source pull request, not
  manually triggered, or currently `recoverable_rate_limited?` (a
  `rate_limited` run with a recovery time, already owned by
  `StaleRunDetectorJob`'s in-place recovery) — avoiding a duplicate,
  competing retry path for state another mechanism already owns.
  *Code:* `Activities::MarkAgentRunFailedActivity#manual_run_retry_eligible?`.
  *Test:* `spec/temporal/activities/mark_agent_run_failed_activity_spec.rb`.

## Partial-work safety

- [x] **MANUAL-RUN-RETRY-003** — The system SHALL only schedule a retry when
  the failed run performed no observable work — zero `iterations`, no
  recorded `pull_request_number`, and no recorded `created_issue_number`
  (`AgentRun#no_observable_work?`). A run with any of those present SHALL
  stay terminally `failed` for an operator rather than risk a duplicate PR
  or issue from a blind retry.
  *Code:* `AgentRun#no_observable_work?`.
  *Test:* `spec/models/agent_run_spec.rb`,
  `spec/temporal/activities/mark_agent_run_failed_activity_spec.rb`.

## Project-level toggle

- [x] **MANUAL-RUN-RETRY-004** — `Project#retry_failed_manual_runs` (boolean,
  default `true`) SHALL gate scheduling, and SHALL be exposed through
  `Project::AUTOMATION_SETTINGS` alongside the project's other automation
  toggles. Disabling it SHALL stop new retries from being scheduled without
  affecting any other automation setting.
  *Code:* `Project::AUTOMATION_SETTINGS`, `db/migrate/20261010054220_add_retry_failed_manual_runs_to_projects.rb`.
  *Test:* `spec/models/project_spec.rb`,
  `spec/temporal/activities/mark_agent_run_failed_activity_spec.rb`,
  `spec/jobs/retry_failed_manual_run_job_spec.rb`.

## Retry chain, cap, and re-check

- [x] **MANUAL-RUN-RETRY-005** — `RetryFailedManualRunJob#perform` SHALL
  re-check eligibility (including the project toggle and
  `no_observable_work?`) under a row lock before acting, since state may
  have changed between scheduling and the delayed job firing. On success it
  SHALL mark the original run `"retried"` (the same terminal status
  review-goal bookkeeping already uses for a superseded run) and create a
  new queued `AgentRun` carrying the original's `project`,
  `initiating_user`, `runner`, `agent_type`, `custom_prompt`, `goal`, and
  `external_metadata` (merged with retry-chain bookkeeping keys) — in that
  order, so the new row never collides with
  `idx_agent_runs_unique_active_lid_planning`. `external_metadata` SHALL be
  carried forward (not reset) because `create_feature` derives its prompt
  from `external_metadata["feature_brief"]`.
  *Code:* `RetryFailedManualRunJob#perform`, `RetryFailedManualRunJob#create_retry_run`.
  *Test:* `spec/jobs/retry_failed_manual_run_job_spec.rb`.

- [x] **MANUAL-RUN-RETRY-006** — The retry chain SHALL be bounded at
  `AgentRun::MAX_MANUAL_RETRY_ATTEMPTS` (3). The attempt number SHALL be
  tracked via `external_metadata[AgentRun::MANUAL_RETRY_ATTEMPT_METADATA_KEY]`
  on each minted run (absent/zero on an original, non-retry run, read
  through `AgentRun#manual_retry_attempt`), incremented by one per retry.
  Once the next attempt would exceed the cap, the scheduler SHALL NOT
  enqueue another `RetryFailedManualRunJob`, and the last attempt SHALL
  remain visible as `failed` on the agent runs page.
  *Code:* `AgentRun::MAX_MANUAL_RETRY_ATTEMPTS`, `AgentRun#manual_retry_attempt`,
  `Activities::MarkAgentRunFailedActivity#schedule_manual_run_retry_if_eligible`.
  *Test:* `spec/temporal/activities/mark_agent_run_failed_activity_spec.rb`,
  `spec/jobs/retry_failed_manual_run_job_spec.rb`.

## Regressions

- [x] **MANUAL-RUN-RETRY-007** — This feature SHALL NOT alter
  issue-attached retry behavior (`MarkAgentRunFailedActivity`'s
  `if agent_run.issue && ...` branch and EAGER-QUEUE-007) or
  `StaleRunDetectorJob`'s scope (unfinished statuses plus in-place
  `rate_limited` recovery).
  *Test:* `spec/temporal/activities/mark_agent_run_failed_activity_spec.rb`,
  `spec/jobs/stale_run_detector_job_spec.rb`,
  `spec/jobs/retry_timed_out_issue_goal_job_spec.rb`.
