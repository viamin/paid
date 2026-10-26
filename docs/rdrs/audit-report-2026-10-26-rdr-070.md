# RDR-070 Recovery Closeout Audit — 2026-10-26

- **RDR**: [RDR-070: Facet Confidence and Adaptive Clarification](RDR-070-facet-confidence-and-clarification.md)
- **Closeout**: [#4323](https://github.com/viamin/paid/issues/4323) — open
- **Tracks**: [#4309](https://github.com/viamin/paid/issues/4309); this audit does not close the umbrella.
- **Follows**: [RDR Closeout Checklist](closeout-checklist.md)
- **Status decision**: **Partially Implemented**

## Conclusion

The recovery prerequisite, [#4596](https://github.com/viamin/paid/issues/4596),
is closed and its shipped code supplies the authorized Inbox evaluation,
sole-judge blinded labeling, frozen reference set, and retained report. This
removes the earlier missing-workflow blocker. It does not establish the
operator-derived acceptance evidence that RDR-070 requires: no authenticated
human reference judge has labeled and frozen all eight corpus cases, and no
resulting evaluator report or corpus-run ledger is present. The RDR therefore
remains **Partially Implemented**.

No implementation child issue is needed for this finding: the tooling owner
has delivered, and #4323 itself remains the explicit final-acceptance work item
for an authorized operator to complete the blinded judgments and report. This
audit does not manufacture human evidence from deterministic fixtures, agent
output, historical issue closure, or the corpus's frozen expected bands.

## Acceptance evidence

| RDR-070 acceptance criterion | Current shipped evidence | Focused test evidence | Result |
| --- | --- | --- | --- |
| Two independent, bounded scores; unknown differs from a score | `app/models/feature_intent_facet_assessment.rb`; `app/services/feature_intents/scoped_readiness.rb` validates finite 0–100 values independently | `spec/services/feature_intents/scoped_readiness_spec.rb` | Satisfied |
| Assessments preserve evidence, revisions, explanation, and use `agent_harness` | `app/services/feature_intents/assess_facet.rb`, `app/jobs/feature_intents/assess_facet_job.rb` | `spec/services/feature_intents/assess_facet_spec.rb` | Satisfied |
| Corrections take precedence and disagreement requests clarification rather than voting | `app/services/feature_intents/challenge_facet_assessment.rb` | `spec/services/feature_intents/challenge_facet_assessment_spec.rb` | Satisfied |
| Adaptive clarification and explicit-preference provenance | `app/services/chat_sessions/build_system_prompt.rb`; `app/services/explicit_preferences/` | Linked `FACET-CONFIDENCE-006` and `007` specs in `docs/intent/facet-confidence/facet-confidence-specs.md` | Satisfied by existing evidence |
| Material-prerequisite mapping, no vacuous readiness, independent default thresholds, research scope | `app/services/feature_intents/scoped_readiness.rb` | `spec/services/feature_intents/scoped_readiness_spec.rb` | Satisfied |
| Frozen representative corpus, provenance/replay guard, and outcome computation | `docs/intent/facet-confidence/assessment-corpus-manifest-v1.yml`, `lib/facet_confidence/assessment_corpus_ledger.rb`, `lib/facet_confidence/assessment_outcome_report.rb` | `spec/lib/facet_confidence/assessment_corpus_ledger_spec.rb`, `spec/lib/facet_confidence/assessment_outcome_report_spec.rb`, `spec/bin/facet_confidence/assessment_evaluation_cli_spec.rb` | Tooling satisfied; measures pending |
| Authorized, blinded human-reference evaluation and retained report | `app/services/facet_confidence/closeout_evaluation/`, `app/controllers/projects/facet_confidence_evaluations_controller.rb`, and the partial-closeout Inbox view | `spec/services/facet_confidence/closeout_evaluation/{start,record_label,freeze_labels}_spec.rb`, `spec/requests/projects/facet_confidence_evaluations_spec.rb` | Tooling satisfied; human judgments/report pending |

## Numerical and policy evidence

`FeatureIntents::ScopedReadiness` requires each mapped prerequisite's intent
and technical score to meet separate project thresholds. The focused spec
proves exact 80/80 readiness, failure for either 79/80 combination, unknown,
pending, stale, malformed, and out-of-range assessments, without averaging.
It also proves a research issue is evaluated against its own mapped
investigation prerequisites.

Explicit preferences are persisted only from an explicit statement and scope;
correction handling supersedes prior evidence rather than counting repetitions.
The 80/80 defaults are provisional policy judgments, not calibrated
probabilities. `FacetConfidence::AssessmentOutcomeReport` keeps threshold or
rubric tuning blocked until all outcome measures exist; throughput alone is
never a tuning justification.

## Measured-acceptance gap and recovery route

The committed outcome worksheet records zero of eight operator-executed corpus
runs and marks false readiness, unnecessary clarification, human corrections,
assessment cost, downstream rework, and band divergences **not established**.
The recovery route is now available in the partial-closeout Inbox item:

1. An authorized operator starts or resumes #4323's evaluation pinned to the
   frozen corpus digest.
2. That same operator records one blinded judgment and cited case evidence for
   every corpus case, then freezes the set.
3. The retained evaluator report and the corpus-run outcome worksheet provide
   the measured evidence for a subsequent final audit.

Only the operator may supply those judgments. Completion of the evaluation
does not close #4323 or #4309, enable delivery, or change the 80/80 defaults.

## Rollout guard and status reconciliation

RDR-070's guard remains satisfied and enforced: readiness-driven release stays
behind the complete RDR-071 delivery path; assessment alone does not change
eligibility, enroll historical features, or pause active runs. The metadata
and [RDR index](README.md) both remain **Partially Implemented**, matching this
evidence. #4323 has `quality` and `P1` labels only—none of the effective
auto-pick skip labels (`planning`, `research`, `waiting`, `tracking`, or
`needs-manual-setup`).

## Verification

Dependencies were installed with `bundle install` and `yarn install
--frozen-lockfile`; the test database was prepared with `RAILS_ENV=test
bin/rails db:prepare`.

```text
bundle exec rspec \
  spec/services/feature_intents/scoped_readiness_spec.rb \
  spec/services/feature_intents/assess_facet_spec.rb \
  spec/services/feature_intents/challenge_facet_assessment_spec.rb \
  spec/services/facet_confidence/closeout_evaluation_packet_spec.rb \
  spec/services/facet_confidence/closeout_evaluation/start_spec.rb \
  spec/services/facet_confidence/closeout_evaluation/record_label_spec.rb \
  spec/services/facet_confidence/closeout_evaluation/freeze_labels_spec.rb \
  spec/lib/facet_confidence/assessment_corpus_ledger_spec.rb \
  spec/lib/facet_confidence/assessment_outcome_report_spec.rb \
  spec/bin/facet_confidence/assessment_evaluation_cli_spec.rb \
  spec/requests/projects/facet_confidence_evaluations_spec.rb
```

Result: **112 examples, 0 failures**.
