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
  *Corpus:* `shadow-evaluation-manifest-2026-10-13.yml` freezes the 30-case
  corpus pinned to repository / base SHA / head SHA / approved design revision
  / model-prompt version.
  *Adjudication:* The prior label-only ledger is not qualifying evidence: its
  entries were introduced under one bot identity, so it cannot prove two
  independent human adjudicators. The corpus requirement remains unmet until
  two distinct, authenticated human operators adjudicate every case while
  blind to reviewer output. Only then may `shadow-run` record reviewer runs.

- [ ] **INTENT-CONFORMANCE-ROLLOUT-003** — The rollout record SHALL measure
  false alarms, missed material drift, escaped changes, reviewer cost, human
  resolution time, rework, and delivery time against a predeclared same-project
  baseline and promotion rule.
  *Design:* `intent-conformance-rollout-design.md`.
  *Worksheet:* `shadow-evaluation-worksheet-2026-10-13.md` records the
  frozen corpus and marks every adjudication- and reviewer-derived measure
  `not established`. The promotion decision stays unestablished until the
  independent human adjudications and reviewer runs exist.

- [x] **INTENT-CONFORMANCE-ROLLOUT-004** — Operators SHALL not release
  feature work into the mode until scanner enforcement and the final merge
  guard are active; rollback SHALL disable both guard flags, stop new mode
  releases, and hold outstanding candidates rather than treating an absent
  review as approval.
  *Design:* `intent-conformance-rollout-design.md`.
