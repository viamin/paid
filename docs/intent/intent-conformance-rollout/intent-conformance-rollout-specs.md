# EARS Specs: Intent-Conformance Measured Rollout

> Testable claims for RDR-067 issue #3870. Status markers: `[x]` implemented
> · `[ ]` active gap · `[D]` deferred.

- [x] **INTENT-CONFORMANCE-ROLLOUT-001** — When a project enables only
  `intent_conformance_shadow_review` for a released feature intent with an
  approved design revision, the system SHALL schedule and run an independent
  conformance review, while the final merge guard remains disabled because it
  continues to require `approved_intent_amendments`.
  *Code:* `app/services/intent_conformance/schedule_review.rb`,
  `app/services/intent_conformance/review_run.rb`,
  `app/services/intent_conformance/verify_at_merge.rb`.
  *Test:* `spec/services/intent_conformance/schedule_review_spec.rb`,
  `spec/services/intent_conformance/review_run_spec.rb`.

- [ ] **INTENT-CONFORMANCE-ROLLOUT-002** — Before a project enables the
  approval-gated operating mode, operators SHALL retain a frozen,
  independently adjudicated corpus containing accepted, intentionally drifted,
  and uncertain PR cases, and SHALL evaluate the reviewer in shadow mode.
  *Design:* `intent-conformance-rollout-design.md`.
  *Gap:* #4205 owns the blinded operator adjudication and completed corpus
  manifest; the shipped scheduler and shadow flag do not constitute a run.

- [ ] **INTENT-CONFORMANCE-ROLLOUT-003** — The rollout record SHALL measure
  false alarms, missed material drift, escaped changes, reviewer cost, human
  resolution time, rework, and delivery time against a predeclared same-project
  baseline and promotion rule.
  *Design:* `intent-conformance-rollout-design.md`.
  *Gap:* #4205 owns the completed, repository-visible aggregate worksheet and
  promotion decision; no adjudicated measurement results are recorded yet.

- [x] **INTENT-CONFORMANCE-ROLLOUT-004** — Operators SHALL not release
  feature work into the mode until scanner enforcement and the final merge
  guard are active; rollback SHALL disable both guard flags, stop new mode
  releases, and hold outstanding candidates rather than treating an absent
  review as approval.
  *Design:* `intent-conformance-rollout-design.md`.
