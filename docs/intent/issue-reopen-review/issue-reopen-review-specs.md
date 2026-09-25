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

- [x] **ISSUE-REOPEN-REVIEW-003** - When the chat issue-editing tool reopens an
  issue that GitHub currently reports as closed, it SHALL require explicit
  confirmation that the prior closure was reviewed and a non-blank reason from
  a caller authorized to manage issues. The tool SHALL consult GitHub state
  rather than relying on the local synchronization mirror.
  *Tests:* `spec/mcp/tools/edit_issue_spec.rb`.
  *Code:* `Tools::EditIssue`.

- [x] **ISSUE-REOPEN-REVIEW-004** - When the chat issue-editing tool reopens an
  issue that GitHub currently reports as closed, it SHALL persist the Paid user,
  time, and reason on the issue, record those details in the account audit trail,
  and place the issue in reopen review. Automatic issue selection SHALL remain
  state-neutral, while completion remains gated until the review is resolved.
  *Tests:* `spec/mcp/tools/edit_issue_spec.rb`,
  `spec/services/issues/upsert_from_github_spec.rb`.
  *Code:* `Tools::EditIssue`, `Issues::UpsertFromGithub`, `Issue`.
