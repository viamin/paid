# EARS Specs: Manual Review Recovery By Cause

- [x] **MANUAL-REVIEW-RECOVERY-001** — When an open issue is parked in
  `manual_review`, the system SHALL classify its cause from the provenance the
  parking producer already recorded — the dedicated reopen-review reason, the
  dependency-wait reason, the enhancement round-limit reason, the
  malformed-structured-output reason, or a code-scanning synthetic issue's
  reason — into `reopen_review`, `dependency_wait`, `enhancement`,
  `scanner_recurrence`, `technical_failure`, or `unknown`. A cause that no
  recorded provenance resolves SHALL remain visible as `unknown` with its
  recorded reason and SHALL NOT be coerced into another cause.
  *Tests:* `spec/services/manual_review_recovery/cause_spec.rb`.
  *Code:* `ManualReviewRecovery::Cause`,
  `ManualReviewRecovery::ReasonSignatures`.

- [x] **MANUAL-REVIEW-RECOVERY-002** — When a parked issue's cause is
  `reopen_review`, the Inbox manual-review pane SHALL show the original
  closure and the remaining scope, and SHALL accept an authorized
  intent-validation decision that names whether the original intent still
  holds, carries the operator's reason, and is bound to the issue's current
  evidence revision. A later change to the issue's evidence SHALL invalidate
  the recorded decision. The decision alone SHALL NOT release the hold; the
  pane SHALL then offer the supported work continuation for that decision.
  *Tests:* `spec/services/manual_review_recovery/recover_spec.rb`,
  `spec/models/issue_reopen_review_decision_spec.rb`,
  `spec/requests/agent_runs_spec.rb`.
  *Code:* `ManualReviewRecovery::Recover`,
  `IssueReopenReviewDecision`, `ManualReviewRecovery::EvidenceRevision`.

- [x] **MANUAL-REVIEW-RECOVERY-003** — When a parked issue's cause is
  `dependency_wait`, the Inbox manual-review pane SHALL name the blocking
  dependency and its owner or repository, SHALL NOT offer an enhancement
  retry, and SHALL record a dependency acknowledgment that leaves the
  dependency unresolved and the issue parked. The pane SHALL re-evaluate the
  dependency and SHALL offer the supported work continuation only once the
  dependency has actually resolved.
  *Tests:* `spec/services/manual_review_recovery/plan_spec.rb`,
  `spec/services/manual_review_recovery/recover_spec.rb`,
  `spec/requests/agent_runs_spec.rb`.
  *Code:* `ManualReviewRecovery::Plan`, `ManualReviewRecovery::Recover`.

- [x] **MANUAL-REVIEW-RECOVERY-004** — When a parked issue's cause is
  `enhancement`, the Inbox manual-review pane SHALL keep the existing
  clarifying-question answer form available when the parked round preserved
  questions, and SHALL keep the enhancement retry available. When the cause
  is `technical_failure` or `scanner_recurrence`, the pane SHALL route to
  those causes' supported recovery actions and SHALL NOT offer an enhancement
  retry.
  *Tests:* `spec/services/manual_review_recovery/plan_spec.rb`,
  `spec/requests/inbox_spec.rb`.
  *Code:* `ManualReviewRecovery::Plan`,
  `app/views/dashboard/_inbox_detail_manual_review.html.erb`.

- [x] **MANUAL-REVIEW-RECOVERY-005** — Before any manual-review recovery
  action queues work, the system SHALL inspect the issue's queued and running
  runs. A queued run with the same goal SHALL be reused and no second run
  SHALL be created; a queued or running run with an incompatible goal SHALL
  be explicitly reconciled, reported to the operator, and SHALL NOT be
  silently ignored. The manual-review hold SHALL NOT be silently cleared
  while an incompatible automatic run remains queued.
  *Tests:* `spec/services/manual_review_recovery/recover_spec.rb`,
  `spec/services/manual_review_recovery/plan_spec.rb`.
  *Code:* `ManualReviewRecovery::Plan`, `ManualReviewRecovery::Recover`.

- [x] **MANUAL-REVIEW-RECOVERY-006** — Every manual-review recovery action
  offered by the Inbox SHALL state whether it records a decision, retries
  analysis, resumes implementation, or collects evidence. The Inbox UI, the
  API, the chat context, and the MCP tool SHALL use the same authorized
  recovery service and SHALL refresh the Inbox from the persisted state after
  the action.
  *Tests:* `spec/services/manual_review_recovery/plan_spec.rb`,
  `spec/serializers/api/v1/inbox_entry_serializer_spec.rb`,
  `spec/mcp/tools/recover_manual_review_spec.rb`.
  *Code:* `ManualReviewRecovery::Plan`, `ManualReviewRecovery::Recover`,
  `Api::V1::InboxEntrySerializer`, `Inbox::ChatContext`,
  `Tools::RecoverManualReview`.

- [x] **MANUAL-REVIEW-RECOVERY-007** — The manual-review recovery service
  SHALL refuse an actor who is not authorized for the issue's project, and
  SHALL refuse an issue outside the actor's account. A repeated submit of the
  same recovery SHALL NOT record a second decision or create a second run.
  *Tests:* `spec/services/manual_review_recovery/recover_spec.rb`,
  `spec/requests/agent_runs_spec.rb`.
  *Code:* `ManualReviewRecovery::Recover`.

- [x] **MANUAL-REVIEW-RECOVERY-008** — The Inbox manual-review pane SHALL
  render the classified cause, the recorded reason, the cause's supported
  recovery actions with their effect, the original closure and remaining
  scope for a reopened issue, the blocking dependency and its owner for a
  dependency-blocked issue, and the existing scanner evidence for a
  scanner-confirmed recurrence.
  *Tests:* `spec/requests/inbox_spec.rb`.
  *Code:* `app/views/dashboard/_inbox_detail_manual_review.html.erb`,
  `Inbox::Queue`.
