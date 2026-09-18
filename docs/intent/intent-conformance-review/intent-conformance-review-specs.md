# EARS Specs: Independent Intent-Conformance Reviewer Run

> Testable claims for RDR-067 independent reviewer run (#3866). Status
> markers: `[x]` implemented · `[ ]` active gap · `[D]` deferred. Each ID is a
> grep target across specs, tests, and code
> (`grep -r INTENT-CONFORMANCE-REVIEW-001`).

- [x] **INTENT-CONFORMANCE-REVIEW-001** — `IntentConformance::ReviewRun`
  SHALL apply only when the PR issue is linked to a `FeatureIntent` and the
  project has the `approved_intent_amendments` flag enabled (the same gate
  `IntentConformance::VerifyAtMerge` uses); otherwise it SHALL be a no-op and
  persist nothing.
  *Code:* `app/services/intent_conformance/review_run.rb`.
  *Test:* `spec/services/intent_conformance/review_run_spec.rb`.

- [x] **INTENT-CONFORMANCE-REVIEW-002** — Every verdict `ReviewRun` persists
  SHALL record the PR head SHA, the feature's approved design revision at
  call time, the reviewer model, cited design claims, cited diff locations,
  a reasoning summary, and an evaluated-at timestamp; the outcome SHALL be
  exactly one of `within_scope`, `material_drift`,
  `uncertain`, or `not_evaluated`.
  *Code:* `app/services/intent_conformance/review_run.rb`,
  `app/models/intent_conformance_verdict.rb`.
  *Test:* `spec/services/intent_conformance/review_run_spec.rb`,
  `spec/models/intent_conformance_verdict_spec.rb`.

- [x] **INTENT-CONFORMANCE-REVIEW-003** — Rails SHALL treat an unsuccessful
  reviewer response, unparseable output, an outcome outside the LLM-selectable
  set, or a `material_drift`/`uncertain` outcome with no cited design claims,
  as `not_evaluated` (fail closed); the reviewer's own outcome label SHALL
  NEVER be persisted without this structural validation (ZFC — Rails
  validates structure, the LLM makes the semantic call).
  *Code:* `app/services/intent_conformance/review_run.rb`.
  *Test:* `spec/services/intent_conformance/review_run_spec.rb`.

- [x] **INTENT-CONFORMANCE-REVIEW-004** — The implementing agent's
  self-reported verification result SHALL reach the reviewer prompt only as
  labeled, non-authoritative context; no code path SHALL set a verdict's
  `outcome` from `AgentRun#verification_result` or any other
  implementer-authored field — outcome SHALL come exclusively from the
  independent reviewer response after structural validation.
  *Code:* `app/services/intent_conformance/review_run.rb`.
  *Test:* `spec/services/intent_conformance/review_run_spec.rb` (self-report
  claims "passed"/in-scope while the reviewer returns `material_drift`; the
  persisted verdict is `material_drift`).

- [x] **INTENT-CONFORMANCE-REVIEW-005** — When the PR issue is not trusted
  (`Issue#trusted?` false), `ReviewRun` SHALL record a `not_evaluated`
  verdict without including any issue or PR content in a reviewer prompt.
  *Code:* `app/services/intent_conformance/review_run.rb`.
  *Test:* `spec/services/intent_conformance/review_run_spec.rb`.

- [x] **INTENT-CONFORMANCE-REVIEW-006** — Each `ReviewRun` call SHALL record
  its verdict against the exact `pr_head_sha` supplied and the feature
  intent's `approved_design_revision` at call time, so a later push (new PR
  head) or design-revision advance (design amendment merge) leaves the
  verdict structurally stale per `IntentConformanceVerdict#current_for?`
  without any additional invalidation step.
  *Code:* `app/services/intent_conformance/review_run.rb`,
  `app/models/intent_conformance_verdict.rb#current_for?`.
  *Test:* `spec/services/intent_conformance/review_run_spec.rb`,
  `spec/services/intent_conformance/verify_at_merge_spec.rb` (integration:
  a `ReviewRun`-authored `within_scope` verdict unblocks merge; a superseding
  push invalidates it).

- [x] **INTENT-CONFORMANCE-REVIEW-007** — When `feature_intent.design_document_paths`
  is empty, or none of the listed paths resolve to readable content at
  `approved_design_revision`, `ReviewRun` SHALL record `not_evaluated`
  without calling the reviewer (no design content to compare against).
  *Code:* `app/services/intent_conformance/review_run.rb`.
  *Test:* `spec/services/intent_conformance/review_run_spec.rb`.
