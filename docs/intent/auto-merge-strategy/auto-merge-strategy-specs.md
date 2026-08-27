# EARS Specs: Auto-Merge Strategy

> Testable claims for auto-merge policy and execution. Status markers:
> `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r AUTO-MERGE-001`).

- [x] **AUTO-MERGE-001** — When a human-authored pull request is evaluated for
  auto-merge, the system SHALL emit a merge decision only when owner approval,
  green checks, mergeability, clear review feedback, completed blocking review
  methods, fresh reviews, and resolved dependencies are all present; otherwise
  it SHALL return a noop result.
  *Code:* `app/services/automation/strategies/auto_merge.rb`.
  *Test:* `spec/services/automation/strategies/auto_merge_spec.rb`.

- [x] **AUTO-MERGE-002** — When a dependency-update bot pull request is
  evaluated for auto-merge, the system SHALL allow the bot path to skip owner
  approval and review-feedback gates, but SHALL still require bot eligibility,
  a supported merge executor author, green checks, mergeability, and resolved
  dependencies before emitting a merge decision.
  *Code:* `app/services/automation/strategies/auto_merge.rb`.
  *Test:* `spec/services/automation/strategies/auto_merge_spec.rb`.

- [x] **AUTO-MERGE-003** — When `DependabotAutoMergeJob` runs for a project in
  dependency auto-merge mode, the system SHALL merge only eligible Dependabot
  PRs, SHALL stop after the first successful merge in a batch, and SHALL add
  the Paid merge label/comment while treating expected merge conflicts or stale
  mergeability failures as logged non-fatal outcomes. When the GitHub App
  merge is rejected for a missing workflow permission and the project has a PAT
  push fallback configured, it SHALL retry the merge with that fallback client.
  Terminal workflow-permission merge rejections SHALL mark the synced PR row
  for the existing merge-permission cooldown and clear that marker after a
  later successful merge.
  *Code:* `app/jobs/dependabot_auto_merge_job.rb`.
  *Test:* `spec/jobs/dependabot_auto_merge_job_spec.rb`.

- [x] **AUTO-MERGE-004** — When Paid evaluates an auto-merge path, the system
  SHALL persist a project-scoped, PR-scoped sanitized attempt record for merge,
  skip, blocker, and expected failure outcomes. Stored diagnostics SHALL redact
  secret material and SHALL NOT persist raw tokens, webhook secrets, raw stack
  traces, or untrusted comment bodies. Attempt rows SHALL be tenant-scoped via
  row-level security keyed on the project's account.
  *Code:* `app/services/auto_merge_attempts/record.rb`,
  `app/models/auto_merge_attempt.rb`, `app/jobs/dependabot_auto_merge_job.rb`,
  `app/jobs/auto_release_evaluation_job.rb`,
  `app/temporal/activities/merge_pull_request_activity.rb`,
  `db/migrate/20260826020009_create_auto_merge_attempts.rb`.
  *Test:* `spec/models/auto_merge_attempt_spec.rb`,
  `spec/migrations/create_auto_merge_attempts_spec.rb`,
  `spec/jobs/dependabot_auto_merge_job_spec.rb`,
  `spec/jobs/auto_release_evaluation_job_spec.rb`,
  `spec/temporal/activities/merge_pull_request_activity_spec.rb`.

- [x] **AUTO-MERGE-005** — When an open pull request is ineligible for
  auto-merge, the system SHALL persist and report the exact authoritative
  blocker signals that failed in the auto-merge evaluation, SHALL distinguish
  failed signals from later checks that were not evaluated because an earlier
  gate already failed, and SHALL format PR diagnostics from that persisted
  snapshot instead of recomputing eligibility in a second implementation.
  *Code:* `app/services/automation/strategies/auto_merge.rb`,
  `app/temporal/activities/scan_paid_prs_activity.rb`,
  `app/services/pull_requests/auto_merge_status.rb`.
  *Test:* `spec/services/automation/strategies/auto_merge_spec.rb`,
  `spec/services/pull_requests/auto_merge_status_spec.rb`,
  `spec/temporal/activities/scan_paid_prs_activity_spec.rb`.
