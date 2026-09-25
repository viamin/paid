# EARS Specs: Issue Reopen Review

- [x] **ISSUE-REOPEN-REVIEW-001** - When GitHub synchronization observes a
  non-pull-request issue transition from closed to open, the system SHALL place
  the issue in manual review with a reopen-review reason, and the system SHALL
  not let an automated completion path overwrite that pending review.
  *Tests:* `spec/services/issues/upsert_from_github_spec.rb`,
  `spec/temporal/activities/update_issue_with_pr_activity_spec.rb`.
  *Code:* `Issues::UpsertFromGithub`, `Issue#require_reopen_review!`,
  `Issue#complete_unless_reopen_review_pending!`, completion activities.

- [x] **ISSUE-REOPEN-REVIEW-002** - While a reopened issue has pending reopen
  review, the system SHALL prevent the chat issue-editing tool from closing it.
  *Tests:* `spec/mcp/tools/edit_issue_spec.rb`.
  *Code:* `Tools::EditIssue`.

- [x] **ISSUE-REOPEN-REVIEW-003** - When the chat issue-editing tool reopens a
  locally known closed issue, it SHALL require explicit confirmation that the
  prior closure was reviewed.
  *Tests:* `spec/mcp/tools/edit_issue_spec.rb`.
  *Code:* `Tools::EditIssue`.
