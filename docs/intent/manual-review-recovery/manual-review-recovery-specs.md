# EARS Specs: Manual Review Recovery

- [x] **MANUAL-REVIEW-RECOVERY-001** — When an issue is in manual review, the
  system SHALL classify a reopen-review hold from its dedicated persisted
  marker rather than from generic reason text.
  *Tests:* `spec/services/inbox/manual_review_recovery_spec.rb`.
  *Code:* `Inbox::ManualReviewRecovery`.

- [x] **MANUAL-REVIEW-RECOVERY-002** — When a manual-review issue has an
  unresolved authoritative dependency, the system SHALL retain the dependency
  hold and expose the blocking issue rather than starting an enhancement run.
  *Tests:* `spec/services/inbox/manual_review_recovery_spec.rb`.
  *Code:* `Inbox::ManualReviewRecovery`.

- [x] **MANUAL-REVIEW-RECOVERY-003** — When a scanner-backed issue enters
  manual review, the system SHALL route it to scanner evidence recovery rather
  than classifying it as an enhancement retry.
  *Tests:* `spec/services/inbox/manual_review_recovery_spec.rb`.
  *Code:* `Inbox::ManualReviewRecovery`.

- [x] **MANUAL-REVIEW-RECOVERY-004** — When existing provenance cannot
  classify a manual-review hold, the system SHALL keep it visible as unknown
  and SHALL not start work implicitly.
  *Tests:* `spec/services/inbox/manual_review_recovery_spec.rb`.
  *Code:* `Inbox::ManualReviewRecovery`.
