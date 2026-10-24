# RDR-070 Closeout Audit — 2026-10-22

## Scope and conclusion

This is the evidence audit for [RDR-070](RDR-070-facet-confidence-and-clarification.md)
and closeout issue [#4323](https://github.com/viamin/paid/issues/4323). It
Tracks [#4309](https://github.com/viamin/paid/issues/4309); it does not close
the umbrella.

**Conclusion: Partially Implemented.** The durable facet-confidence and
readiness contracts are shipped and covered by focused tests. A versioned
assessment corpus with measured false readiness, unnecessary clarification,
human corrections, cost, and rework has not shipped. Closed historical issues
were not used as implementation evidence.

## Acceptance evidence

| RDR-070 criterion | Shipped evidence | Test evidence | Result |
| --- | --- | --- | --- |
| Independent bounded intent and technical judgments, with unknown distinct from a score | `app/models/feature_intent_facet_assessment.rb:4,14`; `app/services/feature_intents/assess_facet.rb:9,23` | `spec/models/feature_intent_facet_assessment_spec.rb`; `spec/services/feature_intents/assess_facet_spec.rb` | Satisfied |
| Attributable, revisioned evidence and asynchronous assessment through `agent_harness` | `app/services/feature_intents/ingest_facet_evidence.rb:7,17`, `app/services/feature_intents/schedule_facet_assessment.rb:6,13`, `app/services/feature_intents/assess_facet.rb:9,23`, and `app/jobs/feature_intents/assess_facet_job.rb:5` | `spec/services/feature_intents/ingest_facet_evidence_spec.rb`, `spec/services/feature_intents/assess_facet_spec.rb`, `spec/services/feature_intents/assess_facet_concurrent_evidence_spec.rb` | Satisfied |
| Corrections supersede prior evidence; disagreement clarifies rather than votes | `app/services/feature_intents/challenge_facet_assessment.rb:7,20` and the assessor rubric at `app/services/feature_intents/assess_facet.rb:104` | `spec/services/feature_intents/challenge_facet_assessment_spec.rb`; conflicting-collaborator example in `spec/services/feature_intents/assess_facet_spec.rb` | Satisfied |
| Adaptive comparative clarification accepts conditional, both/neither, and free-text answers | `app/services/chat_sessions/build_system_prompt.rb:216` | `spec/services/chat_sessions/build_system_prompt_spec.rb` | Satisfied |
| Explicit preferences retain explicit statement, scope, provenance, and authorized lifecycle operations | `app/models/explicit_preference.rb:7`, `app/services/explicit_preferences/`, and `app/mcp/tools/*explicit_preference.rb` | `spec/models/explicit_preference_spec.rb`, `spec/services/explicit_preferences/*_spec.rb`, and `spec/mcp/tools/*explicit_preference_spec.rb` | Satisfied |
| Per-issue material prerequisite map and no vacuous readiness | `app/models/feature_intent_issue_prerequisite_mapping.rb:4`, `app/models/feature_intent_issue_prerequisite.rb:4` | `spec/models/feature_intent_issue_prerequisite_mapping_spec.rb`, `spec/models/feature_intent_issue_prerequisite_spec.rb` | Satisfied |
| Separate configurable 80/80 thresholds, unknown failure, no averaging, and research-scope handling | `app/services/feature_intents/scoped_readiness.rb:12,29,70`; project threshold migration `db/migrate/20261016034711_add_facet_confidence_thresholds_to_projects.rb:6-17` | `spec/services/feature_intents/scoped_readiness_spec.rb`, including exact 80/80 pass, 79/80 failure, unknown, malformed, stale, and research cases | Satisfied |
| Builder context exposes both scores, provenance categories, and no synchronous display-time LLM | `app/services/feature_intents/admitted_intent_context.rb:9`, `app/services/chat_sessions/build_system_prompt.rb:143` | `spec/services/feature_intents/admitted_intent_context_spec.rb`, `spec/services/chat_sessions/build_system_prompt_spec.rb` | Satisfied |
| Versioned representative assessment corpus and outcome measures | No corpus runner, fixture set, versioned report, or metrics aggregation was found | Existing unit examples do not measure false readiness, unnecessary clarification, human corrections, cost, or rework | Gap |

## Numeric and policy findings

`FeatureIntents::ScopedReadiness` admits a prerequisite only when each known,
finite score is within 0–100 and independently meets its project threshold.
The focused spec proves 80/80 passes and either 79/80 combination fails; a
missing, pending, superseded, malformed, or unknown assessment is visibly
not-ready. This is deterministic policy enforcement, not score calibration.

The 80/80 defaults are provisional decision thresholds, not calibrated
probabilities or a guarantee of successful delivery. The audit found no
evidence that scores are tuned to raise throughput; the missing corpus must
measure quality outcomes before any threshold or rubric tuning is proposed.

## Corpus gap and issue filing

The required corpus must cover provisional direction, explicit corrections,
repeated agent suggestions, collaborator disagreement, unknown intent with
strong technical evidence, strong intent with weak feasibility, research
scope, and the 79/80 boundary. It must report false readiness, unnecessary
clarification, human corrections, cost, and downstream rework with corpus,
rubric/model, and input revisions.

The focused child issue is [#4573](https://github.com/viamin/paid/issues/4573).
Closeout [#4323](https://github.com/viamin/paid/issues/4323) explicitly
depends on it for final acceptance, so merging this audit cannot close the
closeout while the required corpus remains outstanding.

## Rollout guard and verification

The RDR-070 shadow-assessment guard is satisfied by the shipped RDR-071
gated-release path: `FeatureIntents::ScopedReadiness` only reports releasable
after complete mapping, current assessments, and merged scoped design evidence;
RDR-071 admission/review wiring remains authoritative. No old feature is
silently enrolled by this audit and no active run is paused because evidence
or thresholds changed.

Dependencies were installed with `bundle install` and `yarn install
--frozen-lockfile`. An initial `bin/rails db:prepare` attempt raced the
database service and failed with `ActiveRecord::ConnectionNotEstablished`; the
subsequent database-backed focused RSpec run completed successfully: **144
examples, 0 failures**. `bin/coherence-check.mjs` completed with the new
`FACET-CONFIDENCE-016` correctly reported as an uncovered active-gap marker;
it also reported pre-existing repository-wide reverse orphans and stale arrow
signals outside this closeout's scope.
