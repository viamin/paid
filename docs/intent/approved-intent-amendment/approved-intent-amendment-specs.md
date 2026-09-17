# EARS Specs: Approved Intent Amendment

> Testable claims for RDR-067 design amendment, revision impact mapping, and
> bounded pause (#3869). Status markers: `[x]` implemented · `[ ]` active gap ·
> `[D]` deferred. Each ID is a grep target across specs, tests, and code
> (`grep -r INTENT-AMENDMENT-001`).

- [x] **INTENT-AMENDMENT-001** — When a human records a one-PR implementation
  exception resolution, the system SHALL bind it to the actor and the exact PR
  head and SHALL reject the record when any approved product commitment
  (behavior, constraints, scope, acceptance criteria) is marked changed.
  *Code:* `app/models/intent_conformance_resolution.rb`,
  `app/services/intent_resolutions/record.rb`.
  *Test:* `spec/models/intent_conformance_resolution_spec.rb`,
  `spec/services/intent_resolutions/record_spec.rb`.

- [x] **INTENT-AMENDMENT-002** — When a human records a resolution that changes
  an approved product commitment, the system SHALL require a design amendment
  and SHALL record the change only on that amendment's resolution.
  *Code:* `app/models/intent_conformance_resolution.rb`,
  `app/services/intent_resolutions/record.rb`.
  *Test:* `spec/models/intent_conformance_resolution_spec.rb`,
  `spec/services/intent_resolutions/record_spec.rb`.

- [x] **INTENT-AMENDMENT-003** — When a design amendment opens, the system
  SHALL bind it to the feature intent and the feature's current approved design
  revision and SHALL mark the feature `revising`; opening SHALL be gated by the
  `approved_intent_amendments` feature flag (default off).
  *Code:* `app/services/design_amendments/open.rb`,
  `app/services/feature_flags.rb`.
  *Test:* `spec/services/design_amendments/open_spec.rb`.

- [x] **INTENT-AMENDMENT-004** — When an approved amendment records its merged
  revision, the system SHALL require a recorded human approval of the amended
  design PR head, advance the feature's approved design revision, and return
  the feature to `released` before impact evaluation.
  *Code:* `app/services/design_amendments/approve.rb`,
  `app/services/design_amendments/complete.rb`.
  *Test:* `spec/services/design_amendments/complete_spec.rb`.

- [x] **INTENT-AMENDMENT-005** — When impact is evaluated, the semantic
  reviewer SHALL map each linked open PR and unstarted issue to `affected`,
  `unaffected`, or `uncertain` citing design claims, and the system SHALL
  treat an unsuccessful, invalid, or low-confidence review as `uncertain` for
  every branch (fail closed).
  *Code:* `app/services/design_amendments/impact_review.rb`,
  `app/services/design_amendments/evaluate_impact.rb`.
  *Test:* `spec/services/design_amendments/impact_review_spec.rb`,
  `spec/services/design_amendments/evaluate_impact_spec.rb`.

- [x] **INTENT-AMENDMENT-006** — The applied pause set SHALL consist of exactly
  the `affected` branches plus their dependency closure (issues that
  transitively depend on a held branch) plus `uncertain` branches;
  `unaffected` branches SHALL receive no hold and remain runnable.
  *Code:* `app/services/design_amendments/pause_set.rb`,
  `app/services/design_amendments/evaluate_impact.rb`.
  *Test:* `spec/services/design_amendments/pause_set_spec.rb`,
  `spec/services/design_amendments/evaluate_impact_spec.rb`.

- [x] **INTENT-AMENDMENT-007** — When a branch's impact is `uncertain`, the
  system SHALL hold it and publish a blocking human-decision notification that
  includes the cited design claims and the reviewer's explanation.
  *Code:* `app/services/design_amendments/evaluate_impact.rb`.
  *Test:* `spec/services/design_amendments/evaluate_impact_spec.rb`.

- [x] **INTENT-AMENDMENT-008** — When a merged PR is affected by the revision
  (or its impact cannot be established), the system SHALL record an open
  follow-up decision with a blocking notification and SHALL NOT automatically
  roll back, revert, or close the merged work; only a human SHALL resolve the
  follow-up.
  *Code:* `app/models/design_amendment_follow_up.rb`,
  `app/services/design_amendments/evaluate_impact.rb`.
  *Test:* `spec/services/design_amendments/evaluate_impact_spec.rb`.

- [x] **INTENT-AMENDMENT-009** — While a design-amendment hold is active, the
  held issue SHALL be excluded from auto-pick, eager-enqueue, and dequeue
  eligibility; releasing the hold SHALL restore eligibility.
  *Code:* `app/models/design_amendment_pause.rb`,
  `app/services/automation/strategies/auto_pick/default_candidate_source.rb`,
  `app/services/design_amendments/release_hold.rb`.
  *Test:* `spec/services/automation/strategies/auto_pick/default_candidate_source_spec.rb`,
  `spec/services/design_amendments/release_hold_spec.rb`.
