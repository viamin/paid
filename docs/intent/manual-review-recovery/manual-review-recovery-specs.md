# EARS Specs: Manual-Review Recovery by Cause

> Parent: [Manual-Review Recovery](manual-review-recovery-design.md)
>
> The IDs below are stable grep targets for implementation and tests.

- [ ] **MANUAL-REVIEW-RECOVERY-001** — When an issue is parked in
  `manual_review`, the system SHALL classify the cause of the park from
  explicit provenance — the dedicated reopen-review reason, the enhancement
  stop paths and preserved clarifying questions, unresolved dependency edges,
  scanner remediation evidence, and the recorded partial-completion assessment
  — and SHALL retain a cause it cannot establish as `unknown` rather than
  inferring one from the prose of a free-text reason. The classification SHALL
  return every applicable cause, so simultaneous holds stay visible.
  *Tests:* `spec/services/issues/manual_review_cause_spec.rb`.
  *Code:* `Issues::ManualReviewCause`, `issues.manual_review_cause`.

- [ ] **MANUAL-REVIEW-RECOVERY-002** — When a parked issue's cause is
  `reopen_review`, the system SHALL show the original closure and the
  remaining scope, and SHALL accept an authorized intent-validation decision
  with a reason, bound to a revision digest of the issue's intent. Recording
  the same verdict for the same revision twice SHALL NOT create a second
  decision, and a verdict recorded against an intent that has since changed
  SHALL NOT satisfy the gate for the new revision.
  *Tests:* `spec/services/issues/manual_review_recovery_spec.rb`,
  `spec/requests/inbox_spec.rb`.
  *Code:* `Issues::ManualReviewRecovery`, `ManualReviewDecision`,
  `Issue#require_reopen_review!`.

- [ ] **MANUAL-REVIEW-RECOVERY-003** — When a parked issue's cause is
  `dependency_wait`, the system SHALL name each unresolved dependency, the
  repository that owns it, and the action that resolves it, and SHALL
  re-evaluate the dependency rather than waive it. While the dependency is
  unresolved the hold SHALL remain, and an acknowledgment SHALL NOT clear it.
  *Tests:* `spec/services/issues/manual_review_recovery_spec.rb`,
  `spec/requests/inbox_spec.rb`.
  *Code:* `Issues::ManualReviewCause`, `Issues::ManualReviewRecovery`.

- [ ] **MANUAL-REVIEW-RECOVERY-004** — When a parked issue's cause is an
  enhancement cause, the system SHALL preserve the clarifying-question answer
  form and the enhancement retry, and SHALL route a technical, parser, or
  transport failure to the retry of the analysis rather than to an answer
  form. When a parked issue's cause is `scanner_recurrence`, the system SHALL
  route it to the scanner recovery action and SHALL NOT offer an enhancement
  retry in its place.
  *Tests:* `spec/services/issues/manual_review_recovery_spec.rb`,
  `spec/requests/inbox_spec.rb`.
  *Code:* `Issues::ManualReviewCause`, `Issues::ManualReviewRecovery`,
  `app/views/dashboard/_inbox_detail_manual_review.html.erb`.

- [ ] **MANUAL-REVIEW-RECOVERY-005** — When a parked issue's cause cannot be
  established, the system SHALL keep the issue visible in the manual-review
  lane with its recorded reason and a recovery the operator can act on.
  *Tests:* `spec/services/issues/manual_review_cause_spec.rb`,
  `spec/requests/inbox_spec.rb`.
  *Code:* `Issues::ManualReviewCause`.

- [ ] **MANUAL-REVIEW-RECOVERY-006** — When a recovery action would resume
  work, the system SHALL inspect the issue's queued and running runs first. A
  run with the same goal SHALL be reused rather than duplicated, and a run
  with a different goal SHALL block the recovery with the conflicting run
  named, so the system does not create a second run and does not silently
  clear a hold while an incompatible automatic run remains queued.
  *Tests:* `spec/services/issues/manual_review_recovery_spec.rb`,
  `spec/requests/agent_runs_spec.rb`.
  *Code:* `Issues::ManualReviewRecovery`.

- [ ] **MANUAL-REVIEW-RECOVERY-007** — When the operator acts on a parked
  issue, the Inbox pane, the chat tools, and the API SHALL route through the
  same authorized service, SHALL state whether the action records a decision,
  retries analysis, resumes implementation, or collects evidence, and the
  Inbox SHALL reflect the new state after the action.
  *Tests:* `spec/services/issues/manual_review_recovery_spec.rb`,
  `spec/requests/inbox_spec.rb`, `spec/requests/agent_runs_spec.rb`,
  `spec/mcp/tools/resolve_manual_review_spec.rb`.
  *Code:* `Issues::ManualReviewRecovery`,
  `app/controllers/projects/agent_runs_controller.rb`,
  `app/mcp/tools/resolve_manual_review.rb`,
  `app/controllers/api/v1/inbox_controller.rb`.

- [ ] **MANUAL-REVIEW-RECOVERY-008** — When a recovery action is submitted
  twice, the system SHALL NOT record a second decision, create a second run,
  or apply the recovery twice. When an operator without the project's
  run-agent authority submits a recovery, the system SHALL refuse it and SHALL
  NOT change the issue's state.
  *Tests:* `spec/services/issues/manual_review_recovery_spec.rb`,
  `spec/requests/agent_runs_spec.rb`.
  *Code:* `Issues::ManualReviewRecovery`.
