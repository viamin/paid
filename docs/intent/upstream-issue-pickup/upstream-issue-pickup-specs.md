# EARS Specs: Upstream Issue Pickup

> Testable claims for upstream issue polling (issue #4079).

- [x] **UPSTREAM-ISSUE-001** - When a Project's `pr_target` is `upstream`,
  the issue poller SHALL read issues, pull requests, and issue comments from
  `Project#issue_target_repository`, which resolves to `upstream_full_name`.
  *Tests:* `spec/temporal/activities/fetch_issues_activity_spec.rb`.
  *Code:* `Project#issue_target_repository`, `FetchIssuesActivity`.

- [x] **UPSTREAM-ISSUE-002** - When polling an upstream repository, the
  system SHALL persist and expose an issue only when its author is trusted by
  the Project. It SHALL log each rejected issue at info level without its body.
  *Tests:* `spec/temporal/activities/fetch_issues_activity_spec.rb`.
  *Code:* `FetchIssuesActivity#trusted_github_issue?`.

- [x] **UPSTREAM-ISSUE-003** - When a run is sourced from a synced upstream
  issue, the system SHALL open and synchronize its PR against the upstream
  repository using the fork-qualified head, so `Closes #N` resolves to the
  source issue. *Tests:* `spec/temporal/activities/create_pull_request_activity_spec.rb`.
  *Code:* `CreatePullRequestActivity#pull_request_repository`.

- [x] **UPSTREAM-ISSUE-004** - When polling upstream issues, the system SHALL
  skip issue comment and label mutations from polling, feature clarification,
  enhancement, and no-output outcome paths, and log each skipped operation at
  info level. *Tests:* `spec/temporal/activities/fetch_issues_activity_spec.rb`,
  `spec/temporal/activities/create_agent_run_activity_spec.rb`,
  `spec/temporal/activities/enhance_issue_activity_spec.rb`, and
  `spec/temporal/activities/handle_no_output_issue_run_activity_spec.rb`.
  *Code:* `Activities::BaseActivity#upstream_issue_write_skipped?` and
  `Issues::UpsertFromGithub.remove_recommend_close_label`.

- [x] **UPSTREAM-ISSUE-005** - When a capped GitHub issue page contains only
  untrusted upstream authors, the system SHALL advance its incremental cursor
  from the complete fetched page while persisting none of those issues.
  *Tests:* `spec/temporal/activities/fetch_issues_activity_spec.rb`.
  *Code:* `FetchIssuesActivity#execute`.

- [x] **UPSTREAM-ISSUE-006** - When a Project's issue target repository
  changes, the system SHALL clear repository-scoped issue sync state and
  archive locally open GitHub issues and pull requests from the previous
  target before reconciling the new target. *Tests:* `spec/models/project_spec.rb`.
  *Code:* `Project#reset_issue_sync_state`, `Project#archive_previous_target_issues`.

- [x] **UPSTREAM-ISSUE-007** - When an upstream author's trusted status is
  revoked, the poller SHALL retire locally open records it previously
  persisted for that author so they are neither displayed nor returned to
  the auto-pick/LLM queue, including through the incremental rescan
  fallback. Own-repository projects SHALL NOT retire records from
  untrusted authors, matching their persist-without-body behavior.
  *Tests:* `spec/temporal/activities/fetch_issues_activity_spec.rb`.
  *Code:* `FetchIssuesActivity#retire_untrusted_upstream_issues`.
