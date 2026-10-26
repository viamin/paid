# RDR-070 Closeout Re-audit — 2026-10-26

- **RDR**: [RDR-070: Facet Confidence and Adaptive Clarification](RDR-070-facet-confidence-and-clarification.md)
- **Closeout issue**: [#4323](https://github.com/viamin/paid/issues/4323)
- **Workflow dependency**: [#4596](https://github.com/viamin/paid/issues/4596), closed after shipping the human-reference evaluation workflow
- **Conclusion**: **Partially Implemented** — deterministic contracts and the evaluation workflow are shipped; authentic blinded human-reference measurement has not been recorded.
- **Umbrella relation**: Tracks [#4309](https://github.com/viamin/paid/issues/4309); this audit does not close it.

## Scope and evidence standard

This re-audit compares RDR-070's Decision, Rollout Guard, and Implementation
and Validation sections with current source, linked EARS claims, and focused
test execution. Closed issue state is not accepted as proof of behavior.

GitHub state checked on 2026-10-26 shows #4316, #4318, #4573, and #4596 closed
while #4323 remains open. #4596's closure establishes that the evaluation
workflow landed; it does not establish a human reference judgment, a frozen
reference set, or measured quality outcomes. The repository's current
[`outcome worksheet`](../intent/facet-confidence/assessment-evaluation-2026-10-23/outcome-worksheet-2026-10-23.md)
therefore remains the authority that all five operator-derived measures are
**not established**.

## Acceptance evidence

| RDR-070 acceptance group | Shipped code and test evidence | Finding |
| --- | --- | --- |
| Independent, bounded two-axis assessments; unknown remains distinct | `app/models/feature_intent_facet_assessment.rb:3-27`; `app/services/feature_intents/scoped_readiness.rb:9-89`; `spec/models/feature_intent_facet_assessment_spec.rb`; `spec/services/feature_intents/scoped_readiness_spec.rb` | Satisfied. Scores validate in `0..100`; a missing or nonnumeric score yields an explicit not-ready blocker. |
| Attributable, revisioned assessment through `agent_harness`; evidence fidelity and correction precedence | `app/services/feature_intents/assess_facet.rb`; `app/services/feature_intents/challenge_facet_assessment.rb:5-56`; `app/services/feature_intents/ingest_facet_evidence.rb`; `spec/services/feature_intents/assess_facet_spec.rb`; `spec/services/feature_intents/challenge_facet_assessment_spec.rb` | Satisfied. A human correction creates attributable evidence, supersedes the named prior evidence, and schedules a fresh revision rather than counting votes. |
| Adaptive clarification and explicit-preference provenance | `app/services/chat_sessions/build_system_prompt.rb`; `app/models/explicit_preference.rb:3-58`; `app/services/explicit_preferences/`; `app/mcp/tools/save_explicit_preference.rb:3-91`; `spec/mcp/tools/save_explicit_preference_spec.rb`; `spec/services/explicit_preferences/persist_spec.rb` | Satisfied. Persisting a preference requires a confirmed explicit statement and scoped, tenant-owned targets; interactions do not write a preference. |
| Material prerequisite coverage and initial scoped readiness | `app/models/feature_intent_issue_prerequisite_mapping.rb`; `app/models/feature_intent_issue_prerequisite.rb`; `app/services/feature_intents/scoped_readiness.rb:29-89`; `spec/services/feature_intents/scoped_readiness_spec.rb` | Satisfied. Empty/unconfirmed coverage fails closed; separate scores are compared to independent project thresholds without averaging. The focused spec proves 80/80 passes and either 79/80 result remains not ready. |
| Builder/display context separates expressed intent, inferred fit, and feasibility without synchronous display-time assessment | `app/services/feature_intents/admitted_intent_context.rb`; `app/services/prompt_assembly/sections/admitted_intent.rb`; `app/services/chat_sessions/build_system_prompt.rb`; `spec/services/feature_intents/admitted_intent_context_spec.rb`; `spec/services/chat_sessions/build_system_prompt_spec.rb` | Satisfied. |
| Versioned representative corpus, replay-safe provenance, and quality-measure computation | `docs/intent/facet-confidence/assessment-corpus-manifest-v1.yml`; `lib/facet_confidence/assessment_corpus_ledger.rb:13-156`; `lib/facet_confidence/assessment_outcome_report.rb`; `spec/lib/facet_confidence/assessment_corpus_ledger_spec.rb`; `spec/lib/facet_confidence/assessment_outcome_report_spec.rb`; `spec/bin/facet_confidence/assessment_evaluation_cli_spec.rb` | Tooling satisfied. The committed corpus covers all eight required shapes, including corrections, repeated agent suggestions, disagreement, unknown intent, research scope, and 79/80. It rejects replayed input and blocks throughput-only tuning. |
| Operator-facing blinded reference evaluation and retained report | `app/services/facet_confidence/closeout_evaluation_packet.rb`; `app/services/facet_confidence/closeout_evaluation/{start,record_label,freeze_labels,compile_report}.rb`; `app/controllers/projects/facet_confidence_evaluations_controller.rb`; `spec/services/facet_confidence/closeout_evaluation_packet_spec.rb`; `spec/services/facet_confidence/closeout_evaluation/{start,record_label,freeze_labels}_spec.rb`; `spec/requests/projects/facet_confidence_evaluations_spec.rb` | Workflow satisfied. It pins corpus/rubric/model/input revisions, blocks with owner/recovery information, enforces sole-judge labeling and freeze-before-report, and does not change readiness or defaults. |
| Measured false readiness, unnecessary clarification, human corrections, cost, and downstream rework | `docs/intent/facet-confidence/assessment-evaluation-2026-10-23/outcome-worksheet-2026-10-23.md:45-72` | **Outstanding external acceptance evidence.** No operator has supplied and frozen blinded reference labels or an evaluator report, so the five measures are not established. Fixtures and deterministic tests are expressly not substitutes. |

## Rollout guard and policy disposition

The guard remains in force. `ScopedReadiness` deterministically enforces the
project's independently configured thresholds and RDR-071 controls release;
this audit does not enroll historical features, release an issue, or pause an
active run. The default 80/80 values are provisional policy judgments, not
calibrated probabilities or a delivery-success guarantee. The corpus/reporting
implementation blocks a tuning proposal until complete outcome measures exist,
and throughput alone is never sufficient.

## Remaining acceptance and ownership

No duplicate audit or implementation issue is filed. #4596 is the focused
implementation owner for the now-shipped evaluation workflow; the sole
remaining item is #4323's own final-acceptance operation: an authorized human
reference judge must complete and freeze the blinded labels through that
workflow, retain the resulting report on the originating Inbox item, and then
re-run this closeout against the measured report. This is not a code gap that
can be truthfully closed by a new fixture, agent-generated label, or issue
status change.

## Verification

On 2026-10-26, the following database-backed focused suite was run after
`bundle install`, `yarn install --frozen-lockfile`, and `bin/rails db:prepare`:

```text
bundle exec rspec \
  spec/models/feature_intent_facet_assessment_spec.rb \
  spec/services/feature_intents/assess_facet_spec.rb \
  spec/services/feature_intents/challenge_facet_assessment_spec.rb \
  spec/mcp/tools/save_explicit_preference_spec.rb \
  spec/services/feature_intents/scoped_readiness_spec.rb \
  spec/lib/facet_confidence/assessment_corpus_ledger_spec.rb \
  spec/lib/facet_confidence/assessment_outcome_report_spec.rb \
  spec/services/facet_confidence/closeout_evaluation_packet_spec.rb \
  spec/services/facet_confidence/closeout_evaluation/start_spec.rb \
  spec/services/facet_confidence/closeout_evaluation/record_label_spec.rb \
  spec/services/facet_confidence/closeout_evaluation/freeze_labels_spec.rb \
  spec/requests/projects/facet_confidence_evaluations_spec.rb
```

The first invocation named a non-existent `issue_readiness_spec.rb` and was
corrected to the actual `scoped_readiness_spec.rb`; only the corrected command
is evidence for this audit. The corrected suite completed with **120 examples,
0 failures**. `bin/lint` completed successfully. `bin/coherence-check.mjs`
completed with pre-existing repository-wide reverse-orphan, active-gap, and
staleness signals; this closeout introduced none of them.
