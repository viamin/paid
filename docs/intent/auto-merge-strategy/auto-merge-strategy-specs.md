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
  later successful merge. When a workflow-permission rejection is terminal
  (no PAT fallback configured, or the configured fallback also failed), the
  system SHALL post exactly one sanitized, marker-deduped PR comment
  identifying the blocker and the next action, using distinct wording for the
  fallback-not-configured and fallback-failed cases, and SHALL NOT include
  raw GitHub error payloads, credential/token values, or stack traces in the
  comment body. No comment SHALL be posted for transient errors or unrelated
  non-403 failures.
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

- [x] **AUTO-MERGE-006** — When a blocking approval exists for a human-authored
  pull request and the PR HEAD commit timestamp is newer than the latest
  blocking approval timestamp, the system SHALL mark the approval as stale
  (treating the PR as not freshly approved) only when at least one commit on
  the first-parent path from HEAD back to the approval commit introduces
  content attributable to the PR author. The first-parent path (the feature
  branch's natural history, equivalent to `git log --first-parent HEAD`) SHALL
  be classified as content-free, and the approval retained as fresh, when
  every commit on that path is a merge commit whose second-parent side is
  reachable from the PR's base branch tip AND whose tree is identical to its
  first-parent tree (no conflict resolution, no author-side change). Commits
  reachable from HEAD but NOT on the first-parent path are content-free by
  transitivity: once a merge's second parent is reachable from the base
  branch tip, every descendant of that second parent in the range is also
  reachable. Any commit that cannot be positively classified as content-free
  SHALL continue to mark the approval stale (fail closed). When the first-
  parent walk exceeds the response cap (matches GitHub's compare response
  cap of 250 commits) the range SHALL be treated as unclassifiable, the
  approval SHALL be marked stale (fail closed), and the truncation SHALL be
  logged. The classification decision SHALL be logged with the commit SHAs
  inspected so a stall is diagnosable.
  *Code:*
  `app/services/automation/signals/pull_request_collector.rb`
  (`#only_base_merge_commits_since?`, `#walk_first_parent_chain`),
  `app/temporal/activities/scan_paid_prs_activity.rb`
  (`#review_stale_for_head?`, `#blocking_approvals_for`,
  `#latest_approval_for`).
  *Test:*
  `spec/services/automation/signals/pull_request_collector_spec.rb`,
  `spec/temporal/activities/scan_paid_prs_activity_spec.rb`.
