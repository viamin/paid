# RDR-070 Closeout Recovery Audit — 2026-10-26

## Scope and conclusion

This audit reconciles [RDR-070](RDR-070-facet-confidence-and-clarification.md)
against current code, focused tests, the versioned corpus artifacts, and the
live closeout state for [#4323](https://github.com/viamin/paid/issues/4323).
It **Tracks [#4309](https://github.com/viamin/paid/issues/4309)** and does not
close the umbrella.

**Conclusion: Partially Implemented.** The deterministic facet-confidence
contracts, corpus/outcome machinery, and the #4596 human-reference evaluation
workflow are shipped. The remaining RDR validation requirement is authentic
operator evidence: no persisted blinded reference judgments or frozen
compiled report establishes measured false readiness, unnecessary
clarification, human corrections, assessment cost, or downstream rework.
The frozen corpus, synthetic fixture ledgers, and closed implementation issues
are not substitutes for that evidence.

## Acceptance evidence

| RDR-070 criterion | Shipped code and artifact evidence | Running test evidence | Status |
| --- | --- | --- | --- |
| Independent 0–100 intent and technical scores; unknown remains distinct | `app/models/feature_intent_facet_assessment.rb`; `app/services/feature_intents/assess_facet.rb` | `spec/models/feature_intent_facet_assessment_spec.rb`, `spec/services/feature_intents/assess_facet_spec.rb` | Satisfied |
| Attributable, revisioned evidence assessed through `agent_harness` | `app/services/feature_intents/ingest_facet_evidence.rb`, `schedule_facet_assessment.rb`, and `assess_facet.rb` | `spec/services/feature_intents/assess_facet_spec.rb` | Satisfied |
| Corrections supersede prior evidence; disagreement prompts clarification | `app/services/feature_intents/challenge_facet_assessment.rb`; assessor rubric in `assess_facet.rb` | `spec/services/feature_intents/challenge_facet_assessment_spec.rb`, `spec/services/feature_intents/assess_facet_spec.rb` | Satisfied |
| Comparative clarification accepts conditional, both/neither, and free-text answers | `app/services/chat_sessions/build_system_prompt.rb` | `spec/services/chat_sessions/build_system_prompt_spec.rb` | Satisfied |
| Explicit preferences have statement, scope, provenance, and authorized lifecycle operations | `app/models/explicit_preference.rb`, `app/services/explicit_preferences/`, `app/mcp/tools/save_explicit_preference.rb` | `spec/services/explicit_preferences/persist_spec.rb`, `context_spec.rb`, `spec/mcp/tools/save_explicit_preference_spec.rb` | Satisfied |
| Material prerequisite maps prevent vacuous readiness | `app/models/feature_intent_issue_prerequisite_mapping.rb`, `app/models/feature_intent_issue_prerequisite.rb` | `spec/services/feature_intents/scoped_readiness_spec.rb` | Satisfied |
| Every known score independently meets configurable thresholds; 79/80 is not ready and 80/80 is ready | `app/services/feature_intents/scoped_readiness.rb` | `spec/services/feature_intents/scoped_readiness_spec.rb` | Satisfied |
| Invalid, failed, stale, and unknown assessments cannot pass readiness | `app/services/feature_intents/scoped_readiness.rb`, `app/services/feature_intents/assess_facet.rb` | `spec/services/feature_intents/scoped_readiness_spec.rb`, `spec/services/feature_intents/assess_facet_spec.rb` | Satisfied |
| Builder and chat context distinguish expressed intent, inferred fit, and demonstrated feasibility without synchronous display-time LLM calls | `app/services/feature_intents/admitted_intent_context.rb`, `app/services/chat_sessions/build_system_prompt.rb` | `spec/services/feature_intents/admitted_intent_context_spec.rb`, `spec/services/chat_sessions/build_system_prompt_spec.rb` | Satisfied |
| Frozen representative corpus, replay protection, and outcome computation | `docs/intent/facet-confidence/assessment-corpus-manifest-v1.yml`, `lib/facet_confidence/assessment_corpus_ledger.rb`, `lib/facet_confidence/assessment_outcome_report.rb` | `spec/lib/facet_confidence/assessment_corpus_ledger_spec.rb`, `spec/lib/facet_confidence/assessment_outcome_report_spec.rb` | Satisfied as tooling |
| Measured false readiness, unnecessary clarification, corrections, cost, and rework | `docs/intent/facet-confidence/assessment-evaluation-2026-10-23/outcome-worksheet-2026-10-23.md` correctly records all measures as `not established` pending operator runs | Deterministic metric tests do not supply human-reference measurements | Pending human evidence |
| Blinded human-reference judgment and retained evaluator report | `app/services/facet_confidence/closeout_evaluation/`, `app/controllers/projects/facet_confidence_evaluations_controller.rb`, `app/views/projects/facet_confidence_evaluations/` | `spec/services/facet_confidence/closeout_evaluation/`, `spec/services/facet_confidence/closeout_evaluation_packet_spec.rb`, `spec/requests/projects/facet_confidence_evaluations_spec.rb` | Satisfied as workflow; pending execution |

## Verification

On 2026-10-26, the focused command below completed with **199 examples, 0
failures**:

```text
bundle exec rspec spec/models/feature_intent_facet_assessment_spec.rb \
  spec/services/feature_intents/assess_facet_spec.rb \
  spec/services/feature_intents/challenge_facet_assessment_spec.rb \
  spec/services/feature_intents/scoped_readiness_spec.rb \
  spec/services/feature_intents/admitted_intent_context_spec.rb \
  spec/services/chat_sessions/build_system_prompt_spec.rb \
  spec/services/explicit_preferences/persist_spec.rb \
  spec/services/explicit_preferences/context_spec.rb \
  spec/mcp/tools/save_explicit_preference_spec.rb \
  spec/lib/facet_confidence/assessment_corpus_ledger_spec.rb \
  spec/lib/facet_confidence/assessment_outcome_report_spec.rb \
  spec/services/facet_confidence/closeout_evaluation_packet_spec.rb \
  spec/services/facet_confidence/closeout_evaluation \
  spec/requests/projects/facet_confidence_evaluations_spec.rb
```

The run proves the structural contract, including numerical bounds, unknown
handling, correction precedence, explicit-preference provenance, 79/80 versus
80/80 readiness, blinded save/resume/freeze behavior, tenant authorization,
and retained compiled reports. It does not prove a human has supplied the
reference labels required for measured acceptance.

## Remaining action and issue reconciliation

The live #4323 issue displays only `quality` and `P1`, neither a built-in
auto-pick skip label. Its #4316, #4318, and #4573 dependencies are closed.
#4596 is also closed and its workflow is present in this repository, so no
implementation gap issue is filed and no duplicate audit is created.

The remaining action belongs to #4323's authenticated operator flow: start or
resume the pinned evaluation, enter one authentic blinded reference judgment
for each case, freeze the labels, and retain the compiled report. Until then,
the outcome worksheet remains the correct report of measurement: all five
outcomes are not established. Rerun this closeout only after that report is
available.

## Rollout guard

The RDR-070 guard remains in force. The corpus and evaluation workflow neither
release an issue nor enroll historical features. Readiness-driven release
remains contingent on the complete RDR-071 delivery path. The 80/80 defaults
are provisional policy judgments, not calibrated probabilities or guarantees;
no threshold or rubric change may be justified by throughput alone. The audit
does not change an active run, enable delivery, or alter thresholds.
