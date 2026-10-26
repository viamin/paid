# RDR-070 Closeout Refresh — 2026-10-26

- **RDR**: [RDR-070: Facet Confidence and Adaptive Clarification](RDR-070-facet-confidence-and-clarification.md)
- **Closeout**: [#4323](https://github.com/viamin/paid/issues/4323)
- **Related implementation**: [#4573](https://github.com/viamin/paid/issues/4573) (closed corpus/reporting machinery) and [#4596](https://github.com/viamin/paid/issues/4596) (closed blinded-reference workflow)
- **Umbrella**: Tracks [#4309](https://github.com/viamin/paid/issues/4309); this audit does not close it.
- **Conclusion**: **Partially Implemented**

## Scope and evidence boundary

This refresh applies the [RDR Closeout Checklist](closeout-checklist.md) to
current source, tests, intent, and the GitHub-visible status of #4323 and
#4596. It reconciles the prior recovery note: #4596 is closed and its source
is present, so it is not a remaining implementation owner. Its closure is not
treated as evidence that a human performed the blinded evaluation.

The committed operator worksheet
[`assessment-evaluation-2026-10-23/outcome-worksheet-2026-10-23.md`](../intent/facet-confidence/assessment-evaluation-2026-10-23/outcome-worksheet-2026-10-23.md)
records zero of eight operator-executed corpus runs and marks false readiness,
unnecessary clarification, human corrections, assessment cost, and downstream
rework **not established**. No persisted #4323 evaluation or frozen
human-reference report is supplied in this checkout. Deterministic specs and
fixture reports prove the machinery; they cannot impersonate human-reference
evidence.

## Criterion reconciliation

| RDR-070 criterion | Current code and spec evidence | Result |
| --- | --- | --- |
| Separate bounded intent and technical assessments; explicit unknown | `app/models/feature_intent_facet_assessment.rb`; `app/services/feature_intents/assess_facet.rb`; `spec/models/feature_intent_facet_assessment_spec.rb`; `spec/services/feature_intents/assess_facet_spec.rb` | Satisfied |
| Revisioned, attributable evidence and asynchronous `agent_harness` assessment | `app/services/feature_intents/ingest_facet_evidence.rb`; `app/services/feature_intents/schedule_facet_assessment.rb`; `app/jobs/feature_intents/assess_facet_job.rb`; `spec/services/feature_intents/assess_facet_concurrent_evidence_spec.rb` | Satisfied |
| Correction precedence and disagreement clarification | `app/services/feature_intents/challenge_facet_assessment.rb`; `spec/services/feature_intents/challenge_facet_assessment_spec.rb`; `spec/services/feature_intents/assess_facet_spec.rb` | Satisfied |
| Adaptive comparative clarification | `app/services/chat_sessions/build_system_prompt.rb`; `spec/services/chat_sessions/build_system_prompt_spec.rb` | Satisfied |
| Explicit-preference provenance and authorized lifecycle | `app/models/explicit_preference.rb`; `app/services/explicit_preferences/`; `app/mcp/tools/*explicit_preference.rb`; matching model, service, and MCP specs | Satisfied |
| Non-vacuous, per-issue facet mapping | `app/models/feature_intent_issue_prerequisite_mapping.rb`; `app/models/feature_intent_issue_prerequisite.rb`; matching model specs | Satisfied |
| Independent configurable 80/80 readiness, 79/80 failure, unknown failure, no averaging, research scope | `app/services/feature_intents/scoped_readiness.rb`; `db/migrate/20261016034711_add_facet_confidence_thresholds_to_projects.rb`; `spec/services/feature_intents/scoped_readiness_spec.rb` | Satisfied |
| Builder context retains independent scores and provenance without display-time LLM work | `app/services/feature_intents/admitted_intent_context.rb`; `app/services/chat_sessions/build_system_prompt.rb`; matching service specs | Satisfied |
| Frozen representative corpus, provenance, replay protection, and metric computation | `docs/intent/facet-confidence/assessment-corpus-manifest-v1.yml`; `lib/facet_confidence/assessment_corpus_ledger.rb`; `lib/facet_confidence/assessment_outcome_report.rb`; their specs | Satisfied as machinery |
| Authorized, blinded human-reference labeling and retained comparison report | `app/services/facet_confidence/closeout_evaluation/`; `app/controllers/projects/facet_confidence_evaluations_controller.rb`; `spec/services/facet_confidence/closeout_evaluation/{start,record_label,freeze_labels}_spec.rb`; `spec/requests/projects/facet_confidence_evaluations_spec.rb` | Satisfied as workflow |
| Measured false readiness, unnecessary clarification, corrections, cost, and rework from authentic evaluation | Worksheet has 0/8 runs and no frozen #4323 reference report | **Not established** |

## Numeric and policy findings

The readiness contract separately compares each known, current assessment with
the independently configured project thresholds. Its focused spec exercises
the exact 80/80 pass and either-axis 79/80 failure, as well as unknown,
malformed, stale, and research-scope outcomes. The assessment and schema
contracts bound numeric values to 0–100; unknown is not converted to a score.

Explicit preferences retain a human statement and provenance. Corrections are
preserved and supersede earlier evidence; disagreement triggers clarification,
not a vote. These are deterministic contract findings, not a calibration
claim. The default 80/80 values remain provisional policy judgments rather
than calibrated probabilities. The outcome-report tuning gate blocks a tuning
proposal until outcome coverage is complete, and throughput alone is never
sufficient.

## Remaining action, rollout guard, and status

No new child issue is filed. #4596 already delivered the specific missing
implementation workflow; creating another audit or duplicate implementation
issue would obscure ownership. The still-required action belongs to the open
closeout #4323: an authorized human must complete and freeze all eight blinded
reference judgments, retain the evaluator report on its originating Inbox
item, and then rerun this evidence audit. Until that happens, measured
acceptance is unavailable and #4323 remains open.

RDR-070 remains **Partially Implemented**, matching its metadata and the
`docs/rdrs/README.md` index. Its rollout guard remains in force: the refresh
does not enroll old work, enable delivery, alter thresholds, or pause active
runs. Confidence-driven release continues to require the RDR-071 gated path.

## Verification

Dependencies were installed with `bundle install` and `yarn install
--frozen-lockfile`. The configured lint and test commands report that no
repository commands are configured. The focused RSpec command covering
assessment, correction, readiness, packet, labeling, freezing, and request
authorization behavior completed **60 examples, 0 failures** on 2026-10-26.

`bin/coherence-check.mjs` completed. It reports repository-wide pre-existing
reverse orphans, active gaps, and mapped/stale arrow signals outside this
closeout; it reports no invalid arrow references. The check is evidence of
linkage and the focused suite is evidence of repeatable contracts. Neither is
evidence of the missing human-reference evaluation.

`bin/rails db:prepare` could not connect because this environment supplied no
reachable PostgreSQL service; the focused RSpec suite nevertheless completed
against its test configuration. No destructive database action was attempted.
