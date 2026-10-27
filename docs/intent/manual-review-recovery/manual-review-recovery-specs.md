---
parent: PAID
prefix: MANUAL-REVIEW-RECOVERY
---

# EARS Specs: Manual Review Recovery

- [x] **MANUAL-REVIEW-RECOVERY-001** — When an issue is parked in
  `manual_review`, the system SHALL classify the cause from explicit
  recorded provenance — the reopen-review reason, the scanner verification
  attempt, the dependency-blocked parking reason, or the enhancement stop
  evidence — and SHALL retain a cause it cannot classify as a visible
  `unknown` cause instead of reporting it as an enhancement stop.
  *Tests:* `spec/services/inbox/manual_review_cause_spec.rb`.
  *Code:* `Inbox::ManualReviewCause`, `Issue::DEPENDENCY_BLOCKED_REASON_MARKER`.

- [x] **MANUAL-REVIEW-RECOVERY-002** — When an issue is parked for a reopen
  review, the system SHALL show the original closure and the remaining scope
  and SHALL accept an authorized intent-validation decision with the
  operator's reason, bound to the revision of the scope the operator
  reviewed. The system SHALL refuse a decision whose revision no longer
  matches, SHALL refuse a second decision, and SHALL release only the reopen
  gate: an unresolved dependency SHALL keep the issue parked.
  *Tests:* `spec/services/issues/resolve_reopen_review_spec.rb`,
  `spec/requests/agent_runs_spec.rb`.
  *Code:* `Issues::ResolveReopenReview`, `Issue#reopen_review_pending?`,
  `Issue#reopen_review_stale?`, `Projects::AgentRunsController#resolve_reopen_review`.

- [x] **MANUAL-REVIEW-RECOVERY-003** — When an issue is parked because a
  dependency is unresolved, the system SHALL link the blocking work and its
  owner, SHALL re-evaluate the issue when that dependency resolves, and
  SHALL NOT offer an enhancement retry for it. Recording a decision SHALL
  NOT waive the dependency.
  *Tests:* `spec/services/inbox/manual_review_cause_spec.rb`,
  `spec/services/issues/release_dependency_blocked_dependents_spec.rb`,
  `spec/services/issues/resolve_reopen_review_spec.rb`.
  *Code:* `Inbox::ManualReviewCause`, `Issues::ReleaseDependencyBlockedDependents`,
  `Issues::ResolveReopenReview`.

- [x] **MANUAL-REVIEW-RECOVERY-004** — When an issue is parked for an
  enhancement cause, the system SHALL keep the preserved clarifying-question
  answer form and the enhancement retry, and SHALL route a technical,
  parser or transport failure to that retry and a scanner-confirmed
  recurrence to the supported remediation action.
  *Tests:* `spec/services/inbox/manual_review_cause_spec.rb`,
  `spec/services/issues/resume_manual_review_spec.rb`,
  `spec/requests/inbox_spec.rb`.
  *Code:* `Inbox::ManualReviewCause`, `Issues::ResumeManualReview`,
  `app/views/dashboard/_inbox_detail_manual_review.html.erb`.

- [x] **MANUAL-REVIEW-RECOVERY-005** — When a resume is requested for a
  parked issue, the system SHALL inspect the work that is already queued or
  running before creating anything: a queued run with the same goal SHALL be
  reused, a queued run with a different goal SHALL be reported with its
  identity while the hold stays, and the system SHALL NOT create a second run
  for the same issue and goal.
  *Tests:* `spec/services/issues/resume_manual_review_spec.rb`,
  `spec/requests/agent_runs_spec.rb`.
  *Code:* `Issues::ResumeManualReview`,
  `Projects::AgentRunsController#resume_manual_review`.

- [x] **MANUAL-REVIEW-RECOVERY-006** — When the Inbox offers a recovery for
  a parked issue, it SHALL state whether the action records a decision,
  retries analysis, resumes implementation or collects evidence, and the API
  payload and the inbox chat context SHALL expose the same classification and
  the same supported actions as the pane.
  *Tests:* `spec/requests/inbox_spec.rb`,
  `spec/requests/api/v1/inbox_spec.rb`,
  `spec/services/inbox/chat_context_spec.rb`.
  *Code:* `app/views/dashboard/_inbox_manual_review_actions.html.erb`,
  `Api::V1::InboxEntrySerializer`, `Inbox::ChatContext`.

- [x] **MANUAL-REVIEW-RECOVERY-007** — When a recovery is requested, the
  system SHALL authorize the actor against the issue's account, SHALL refuse
  a request for an issue that already left `manual_review`, and SHALL refuse a
  repeated submission without queuing a second run.
  *Tests:* `spec/services/issues/resume_manual_review_spec.rb`,
  `spec/services/issues/resolve_reopen_review_spec.rb`,
  `spec/requests/agent_runs_spec.rb`.
  *Code:* `Issues::ResumeManualReview`, `Issues::ResolveReopenReview`.
