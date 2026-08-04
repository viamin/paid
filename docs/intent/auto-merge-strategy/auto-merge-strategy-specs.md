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
  green checks, mergeability, and resolved dependencies before emitting a
  merge decision.
  *Code:* `app/services/automation/strategies/auto_merge.rb`.
  *Test:* `spec/services/automation/strategies/auto_merge_spec.rb`.

- [x] **AUTO-MERGE-003** — When `DependabotAutoMergeJob` runs for a project in
  dependency auto-merge mode, the system SHALL merge only eligible Dependabot
  PRs, SHALL stop after the first successful merge in a batch, and SHALL add
  the Paid merge label/comment while treating expected merge conflicts or stale
  mergeability failures as logged non-fatal outcomes.
  *Code:* `app/jobs/dependabot_auto_merge_job.rb`.
  *Test:* `spec/jobs/dependabot_auto_merge_job_spec.rb`.
