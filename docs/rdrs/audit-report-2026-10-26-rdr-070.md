# RDR-070 Recovery Audit — 2026-10-26

## Scope and conclusion

This recovery audit rechecks [RDR-070](RDR-070-facet-confidence-and-clarification.md)
for closeout [#4323](https://github.com/viamin/paid/issues/4323). It Tracks
[#4309](https://github.com/viamin/paid/issues/4309); it does not close the
umbrella.

**Conclusion: Partially Implemented.** Current source includes the durable
facet-confidence contracts, the frozen versioned corpus and reporting
machinery, and the #4596 persisted blinded-reference workflow. The required
authentic human-reference judgments and measured acceptance report do not yet
exist. A queued #4596 run is not a completed judgment and fixture-ledger
examples are not measured human-reference acceptance.

No duplicate gap was filed. [#4596](https://github.com/viamin/paid/issues/4596)
already owns precisely the remaining live evaluation, including its operator
workflow and measured report. Final acceptance of #4323 remains dependent on
that issue. Historical closure of #4316, #4318, #4573, or earlier facet tasks
was not treated as evidence.

## Acceptance evidence

| RDR-070 criterion | Current code and specification evidence | Focused test evidence | Result |
| --- | --- | --- | --- |
| Separate 0–100 intent and technical judgments; unknown is not a score | `app/models/feature_intent_facet_assessment.rb:7-16`; `docs/intent/facet-confidence/facet-confidence-specs.md` (`FACET-CONFIDENCE-001`) | `spec/models/feature_intent_facet_assessment_spec.rb`; `spec/services/feature_intents/scoped_readiness_spec.rb` | Satisfied |
| Evidence is attributable, revisioned, asynchronously assessed through `agent_harness` | `app/services/feature_intents/ingest_facet_evidence.rb`; `app/services/feature_intents/schedule_facet_assessment.rb`; `app/services/feature_intents/assess_facet.rb` | `spec/services/feature_intents/ingest_facet_evidence_spec.rb`; `spec/services/feature_intents/assess_facet_spec.rb`; `spec/services/feature_intents/assess_facet_concurrent_evidence_spec.rb` | Satisfied |
| Explicit corrections supersede prior evidence; disagreement clarifies rather than votes | `app/services/feature_intents/challenge_facet_assessment.rb:20-27`; assessor rubric in `app/services/feature_intents/assess_facet.rb` | `spec/services/feature_intents/challenge_facet_assessment_spec.rb`; `spec/services/feature_intents/assess_facet_spec.rb` | Satisfied |
| Clarification accepts comparative, conditional, both/neither, and free-text answers | `app/services/chat_sessions/build_system_prompt.rb`; `FACET-CONFIDENCE-006` | `spec/services/chat_sessions/build_system_prompt_spec.rb` | Satisfied |
| Only explicit preferences are durable and retain scope/provenance | `app/models/explicit_preference.rb`; `app/services/explicit_preferences/`; `FACET-CONFIDENCE-007` | `spec/models/explicit_preference_spec.rb`; `spec/services/explicit_preferences/*_spec.rb`; `spec/mcp/tools/*explicit_preference_spec.rb` | Satisfied |
| Material prerequisite mapping prevents vacuous readiness | `app/models/feature_intent_issue_prerequisite_mapping.rb`; `app/models/feature_intent_issue_prerequisite.rb` | `spec/models/feature_intent_issue_prerequisite_mapping_spec.rb`; `spec/models/feature_intent_issue_prerequisite_spec.rb` | Satisfied |
| Each axis independently meets configured thresholds; unknown/stale/invalid fails; 80/80 passes and 79/80 fails | `app/services/feature_intents/scoped_readiness.rb`; `db/migrate/20261016034711_add_facet_confidence_thresholds_to_projects.rb` | `spec/services/feature_intents/scoped_readiness_spec.rb` | Satisfied |
| Builder context preserves both scores and provenance without display-time LLM calls | `app/services/feature_intents/admitted_intent_context.rb`; `app/services/chat_sessions/build_system_prompt.rb` | `spec/services/feature_intents/admitted_intent_context_spec.rb`; `spec/services/chat_sessions/build_system_prompt_spec.rb` | Satisfied |
| Frozen representative corpus, provenance, replay protection, and required outcome calculations | `docs/intent/facet-confidence/assessment-corpus-manifest-v1.yml`; `lib/facet_confidence/assessment_corpus_ledger.rb`; `lib/facet_confidence/assessment_outcome_report.rb`; `FACET-CONFIDENCE-016`–`018` | `spec/lib/facet_confidence/assessment_corpus_ledger_spec.rb`; `spec/lib/facet_confidence/assessment_outcome_report_spec.rb`; `spec/bin/facet_confidence/assessment_evaluation_cli_spec.rb` | Mechanism satisfied; measured result pending |
| Blinded human-reference evaluation, sole judge, freeze, and retained report | `app/models/facet_confidence_evaluation.rb`; `app/services/facet_confidence/closeout_evaluation/`; `FACET-CONFIDENCE-020`–`021` | `spec/services/facet_confidence/closeout_evaluation/*_spec.rb`; `spec/requests/projects/facet_confidence_evaluations_spec.rb` | Mechanism satisfied; live reference set pending |

## Measured-acceptance gap and rerun condition

The worksheet records all five RDR measures—false readiness, unnecessary
clarification, human corrections, assessment cost, and downstream rework—as
`not established` until all eight corpus cases have genuine operator runs.
See
[`assessment-evaluation-2026-10-23/outcome-worksheet-2026-10-23.md`](../intent/facet-confidence/assessment-evaluation-2026-10-23/outcome-worksheet-2026-10-23.md).
The #4596 workflow is the required path: an authorized operator starts or
resumes the digest-pinned evaluation, records every blinded judgment, freezes
the reference set, and retains the compiled comparison report. Only then can
this audit be rerun against measured evidence.

The 80/80 defaults remain provisional policy judgments, not calibrated
probabilities or a delivery guarantee. The corpus report blocks tuning until
its measures are complete; increasing throughput alone cannot justify score,
rubric, or threshold tuning. The deterministic 79/80 boundary proof is not a
substitute for calibration evidence.

## Rollout guard and verification

RDR-070's rollout guard remains intact. The evaluation packet explicitly
states that starting or freezing an evaluation cannot close its source issue,
enable delivery, or change the 80/80 defaults; readiness-driven release stays
on the complete RDR-071 path. This audit does not enroll historical features,
change a threshold, or modify active-run state.

`bundle install`, `yarn install --frozen-lockfile`, and `bin/rails db:prepare`
completed successfully. The focused RSpec command completed with **122
examples, 0 failures**: it covered assessment bounds/evidence/corrections,
scoped readiness, explicit preferences, corpus ledger and outcome reporting,
the evaluation command, persisted blinded evaluation services, and authorized
request behavior. `bin/coherence-check.mjs` completed; its reverse-orphan and
uncovered-gap output is pre-existing repository-wide work outside this
closeout. `bin/lint` completed successfully.
