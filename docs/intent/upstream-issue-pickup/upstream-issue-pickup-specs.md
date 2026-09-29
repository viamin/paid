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
  skip label mutations and log the skipped operation at info level.
  *Tests:* `spec/temporal/activities/fetch_issues_activity_spec.rb`.
  *Code:* `FetchIssuesActivity#upstream_issue_write_skipped?`,
  `Issues::UpsertFromGithub.remove_recommend_close_label`.
