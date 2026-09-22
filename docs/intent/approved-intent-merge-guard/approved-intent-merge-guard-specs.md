# EARS Specs: Approved Intent Final-Merge Guard

> Testable claims for RDR-067 final-merge precondition (#3868). Status
> markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred. Each ID is a
> grep target across specs, tests, and code
> (`grep -r INTENT-MERGE-GUARD-001`).

- [x] **INTENT-MERGE-GUARD-001** — For approval-gated features, the final-merge guard SHALL apply only when
  the merging issue is linked to a `FeatureIntent` and the project has the
  `approved_intent_amendments` flag enabled; otherwise it SHALL be a no-op and
  every existing merge precondition SHALL be unaffected.
  *Code:* `app/services/intent_conformance/verify_at_merge.rb`.
  *Test:* `spec/services/intent_conformance/verify_at_merge_spec.rb`.

- [x] **INTENT-MERGE-GUARD-002** — For approval-gated features, when no `IntentConformanceVerdict` exists
  for the issue, the guard SHALL block merge; a missing verdict SHALL NOT be
  interpreted as approval (fail closed).
  *Code:* `app/services/intent_conformance/verify_at_merge.rb`,
  `app/models/intent_conformance_verdict.rb`.
  *Test:* `spec/services/intent_conformance/verify_at_merge_spec.rb`,
  `spec/temporal/activities/merge_pull_request_activity_spec.rb`.

- [x] **INTENT-MERGE-GUARD-003** — For approval-gated features, when the current PR head SHA differs from
  the recorded verdict's PR head (a push happened after the verdict), the
  guard SHALL block merge regardless of the verdict's outcome.
  *Code:* `app/services/intent_conformance/verify_at_merge.rb`,
  `app/models/intent_conformance_verdict.rb#current_for?`.
  *Test:* `spec/services/intent_conformance/verify_at_merge_spec.rb`,
  `spec/temporal/activities/merge_pull_request_activity_spec.rb`.

- [x] **INTENT-MERGE-GUARD-004** — For approval-gated features, when the feature intent's approved design
  revision differs from the verdict's recorded approved design revision, or
  the feature intent is `revising`, the guard SHALL block merge.
  *Code:* `app/services/intent_conformance/verify_at_merge.rb`.
  *Test:* `spec/services/intent_conformance/verify_at_merge_spec.rb`,
  `spec/temporal/activities/merge_pull_request_activity_spec.rb`.

- [x] **INTENT-MERGE-GUARD-005** — For approval-gated features, while the issue has an active (held)
  `DesignAmendmentPause`, the guard SHALL block merge regardless of verdict
  state.
  *Code:* `app/services/intent_conformance/verify_at_merge.rb`.
  *Test:* `spec/services/intent_conformance/verify_at_merge_spec.rb`,
  `spec/temporal/activities/merge_pull_request_activity_spec.rb`.

- [x] **INTENT-MERGE-GUARD-006** — For approval-gated features, a current verdict (matching PR head and
  approved design revision) with outcome `within_scope` SHALL allow merge to
  proceed to the project's other existing merge preconditions.
  *Code:* `app/services/intent_conformance/verify_at_merge.rb`.
  *Test:* `spec/services/intent_conformance/verify_at_merge_spec.rb`,
  `spec/temporal/activities/merge_pull_request_activity_spec.rb`.

- [x] **INTENT-MERGE-GUARD-007** — For approval-gated features, a current verdict with outcome
  `material_drift`, `uncertain`, or `not_evaluated` SHALL block merge unless a
  currently valid `implementation_exception` `IntentConformanceResolution`
  bound to the exact current PR head exists; a `require_within_scope`
  resolution SHALL NOT authorize merge.
  *Code:* `app/services/intent_conformance/verify_at_merge.rb`.
  *Test:* `spec/services/intent_conformance/verify_at_merge_spec.rb`.

- [x] **INTENT-MERGE-GUARD-008** — For approval-gated features, the guard SHALL re-verify PR head,
  approved design revision, and verdict identity from data fetched at merge
  time (not a cached scan-time signal), so a push or design amendment
  occurring after scanning but before merge execution is caught.
  *Code:* `app/temporal/activities/merge_pull_request_activity.rb#intent_conformance_blocker`.
  *Test:* `spec/temporal/activities/merge_pull_request_activity_spec.rb`
  (scan-to-merge race examples).
