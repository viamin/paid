# RDR-070 Closeout Audit — 2026-10-26

## Scope and conclusion

This is the evidence audit for
[RDR-070](RDR-070-facet-confidence-and-clarification.md) and closeout issue
[#4323](https://github.com/viamin/paid/issues/4323). It Tracks
[#4309](https://github.com/viamin/paid/issues/4309); it does not close the
umbrella, and it does not close #4323.

**Conclusion: Partially Implemented** — unchanged in status. Every durable
facet-confidence contract has shipped code and passing focused tests, and
the #4596 blinded reference-evaluation workflow has now shipped and been
exercised live against the real closeout entry path. The **measured**
acceptance the issue requires is still not established, for two
separately-owned reasons recorded below. Closed issues (#4316, #4318, #4573)
were not used as implementation evidence; code and running tests were.

Per the 2026-10-24 recovery-owner note, this audit preserves #4596 as the
implementation owner of the measured evaluation workflow, files no duplicate
audit or child issue for it, and does not attest corpus/test-fixture results
as measured human-reference acceptance.

## Acceptance evidence

Re-verified 2026-10-26 against current source with live, database-backed
`bundle exec rspec` runs (all green, counts below).

| RDR-070 criterion | Shipped evidence | Test evidence | Result |
| --- | --- | --- | --- |
| Independent bounded intent and technical judgments, unknown distinct from a score | `app/models/feature_intent_facet_assessment.rb:12-14` (0..100 integer bounds, `allow_nil` unknown); `app/services/feature_intents/assess_facet.rb` | `spec/models/feature_intent_facet_assessment_spec.rb`; `spec/services/feature_intents/assess_facet_spec.rb` ("preserves unknown independently from rejection or approval", "requires independently bounded scores") | Satisfied |
| Attributable, revisioned evidence and asynchronous assessment through `agent_harness` | `app/services/feature_intents/ingest_facet_evidence.rb`, `app/services/feature_intents/schedule_facet_assessment.rb`, `app/services/feature_intents/assess_facet.rb`, `app/jobs/feature_intents/assess_facet_job.rb` | `spec/services/feature_intents/ingest_facet_evidence_spec.rb`, `assess_facet_spec.rb`, `assess_facet_concurrent_evidence_spec.rb` ("rejects output made obsolete by concurrent evidence") | Satisfied |
| Corrections supersede prior evidence; disagreement clarifies rather than votes | `app/services/feature_intents/challenge_facet_assessment.rb`; rubric contract at `app/services/feature_intents/assess_facet.rb:114` | `spec/services/feature_intents/challenge_facet_assessment_spec.rb` ("records a chat correction, supersedes the contradicted statement, and queues reassessment"); `assess_facet_spec.rb` ("leaves conflicting collaborators unresolved rather than selecting a majority direction") | Satisfied |
| Repeated agent suggestions and incidental interactions are not agreement | `app/services/feature_intents/ingest_facet_evidence.rb` (idempotent ingestion); rubric at `assess_facet.rb:114` | `ingest_facet_evidence_spec.rb` ("is idempotent for repeated source ingestion"); corpus case `FC-CORPUS-03` covers the shape | Satisfied |
| Adaptive comparative clarification with conditional, both/neither, free-text answers | `app/services/chat_sessions/build_system_prompt.rb` | `spec/services/chat_sessions/build_system_prompt_spec.rb` | Satisfied |
| Explicit preferences retain statement, scope, provenance, authorized lifecycle; never inferred from behavior | `app/models/explicit_preference.rb:12-23` (owner/recorder/scope targets; statement presence; no behavior-derived write path), `app/services/explicit_preferences/`, `app/mcp/tools/*explicit_preference.rb` | `spec/models/explicit_preference_spec.rb`, `spec/services/explicit_preferences/persist_spec.rb`, `context_spec.rb`, `spec/mcp/tools/save_explicit_preference_spec.rb` | Satisfied |
| Per-issue material prerequisite map; no vacuous readiness | `app/models/feature_intent_issue_prerequisite_mapping.rb`, `app/models/feature_intent_issue_prerequisite.rb` | `spec/models/feature_intent_issue_prerequisite_mapping_spec.rb`, `feature_intent_issue_prerequisite_spec.rb`; `scoped_readiness_spec.rb` ("does not treat a completed empty prerequisite mapping as ready") | Satisfied |
| Separate configurable thresholds, unknown failure, no averaging, research scope | `app/services/feature_intents/scoped_readiness.rb:65-76,101,109-110` (`score_blocker` fails unknown, non-finite, and below-threshold per axis independently); `db/migrate/20261016034711_add_facet_confidence_thresholds_to_projects.rb` (defaults 80/80) | `spec/services/feature_intents/scoped_readiness_spec.rb` ("passes exactly at the independent default thresholds", "fails each independent 79/80 boundary without averaging scores", "fails assessments with scores outside the bounded finite 0-100 range", "assesses a research issue only through its mapped investigation prerequisites") | Satisfied |
| Builder context exposes both scores, provenance categories, no synchronous display-time LLM | `app/services/feature_intents/admitted_intent_context.rb`, `app/services/chat_sessions/build_system_prompt.rb` | `spec/services/feature_intents/admitted_intent_context_spec.rb`, `build_system_prompt_spec.rb` | Satisfied |
| Frozen, versioned representative corpus with per-case evidence, thresholds, expected bands, rationale | `docs/intent/facet-confidence/assessment-corpus-manifest-v1.yml` (`facet-confidence-corpus-v1`, 8 required shapes); `lib/facet_confidence/assessment_corpus_ledger.rb` | `spec/lib/facet_confidence/assessment_corpus_ledger_spec.rb` | Satisfied (#4573) |
| Per-run provenance, replay guard, correction-revision re-runs | `lib/facet_confidence/assessment_corpus_ledger.rb`; `bin/facet-confidence-assessment-evaluation` | `spec/lib/facet_confidence/assessment_corpus_ledger_spec.rb`, `spec/bin/facet_confidence/assessment_evaluation_cli_spec.rb` | Satisfied (#4573) |
| Outcome metrics (false readiness, unnecessary clarification, corrections, cost, rework) and tuning gate | `lib/facet_confidence/assessment_outcome_report.rb`; `bin/facet-confidence-assessment-evaluation compile` | `spec/lib/facet_confidence/assessment_outcome_report_spec.rb` (metric computation incl. `ScopedReadiness` parity at 79/80 and 80/80 against fixture ledgers) | Machinery satisfied; **measured values not established** |
| Closeout-evaluation Inbox packet and persisted blinded reference flow (#4596) | `app/services/facet_confidence/closeout_evaluation_packet.rb`; `app/services/facet_confidence/closeout_evaluation/{start,record_label,freeze_labels,compile_report,case_view}.rb`; `app/controllers/projects/facet_confidence_evaluations_controller.rb`; `app/views/dashboard/_inbox_detail_partial_closeout.html.erb` | `spec/services/facet_confidence/closeout_evaluation_packet_spec.rb`, `closeout_evaluation/{start,record_label,freeze_labels}_spec.rb`, `spec/requests/projects/facet_confidence_evaluations_spec.rb`, `spec/migrations/create_facet_confidence_evaluations_spec.rb` | Satisfied (with one defect found and fixed by this audit, below) |

Focused suite results from this session (development database, 2026-10-26):

- Core judgment/readiness suites (scoped readiness, assessment model+service,
  concurrent evidence, challenge, ingest): **32 examples, 0 failures**.
- Corpus, CLI, explicit preferences, and the full #4596 workflow suites
  (packet, start/record/freeze, requests, migration): **104 examples, 0
  failures** after the fix below (34 in the packet/closeout-evaluation and
  request files directly covering it).
- Prerequisite mapping, builder context, chat prompt, and assessment jobs:
  **132 examples, 0 failures**.

A final combined re-run of all the suites above after the packet fix:
**269 examples, 0 failures**.

## Numeric and policy findings (issue checklist items)

- **Numerical bounds**: `FeatureIntentFacetAssessment` validates both scores as
  integers in 0..100 with unknown represented by nil
  (`app/models/feature_intent_facet_assessment.rb:14`);
  `FeatureIntents::ScopedReadiness#score_blocker` rejects non-finite and
  out-of-range values visibly (`scoped_readiness.rb:70-76`), proven by
  "fails assessments with scores outside the bounded finite 0-100 range".
- **Unknown handling**: unknown never passes a threshold — the axis reports
  `*_unknown` as a blocker (`scoped_readiness.rb:71`); a completed assessment
  with an unknown axis is refused ("does not accept a completed assessment
  with an unknown axis").
- **Explicit preference provenance**: every preference row carries the owner,
  recorder, explicit statement, and an explicit scope target
  (`app/models/explicit_preference.rb:12-23`); no write path derives
  preferences from clicks, usage, or agent interpretation, and correction and
  deletion go through the authorized services/MCP tools.
- **Correction precedence**: an explicit correction supersedes the contradicted
  statement instead of being outvoted by repetition; collaborator conflict
  returns `clarification_needed` rather than a majority verdict
  (`assess_facet.rb:114`, challenge service; both proven by name in the suite
  output above).
- **79/80 readiness behavior**: 80/80 passes exactly; either axis at 79 with
  the other at 80 fails with a per-axis blocker and no averaging
  ("fails each independent 79/80 boundary without averaging scores"), and the
  outcome-report spec proves the same boundary in the corpus metric path.
- **80/80 defaults are provisional judgments**: the thresholds remain
  provisional policy settings, not calibrated probabilities and not a
  guarantee of successful delivery. This audit tuned nothing: no rubric,
  score, or threshold was changed to raise throughput, and the corpus tuning
  gate stays `blocked_incomplete_coverage` until measured metrics exist.

## 2026-10-26 blinding incident in the shipped packet (found and fixed)

Running the real entry path — not the specs — exposed a defect in the
shipped #4596 surface: `CloseoutEvaluationPacket` built `input_revisions`
with `cases.index_with { ... }`, which uses each **entire corpus case hash
as the map key**. Any programmatic consumer of the packet (an operator
script, a debug dump, future view code iterating the map) received the full
frozen cases — including the `expected` verdict/bands/readiness, the
`shape`, and the `selection_rationale` that FACET-CONFIDENCE-021 requires
to stay hidden until freeze. The shipped ERB only reads `.values`/`.size`,
so the HTML never displayed the keys, but the answer key traveled in the
structure itself.

This audit's own operator dump triggered exactly that leak, which:

1. **Disqualified this auditor as reference judge.** The judge saw the frozen
   expectations before labeling, so no judgments were recorded: the started
   evaluation generation was destroyed as contaminated rather than frozen
   with post-exposure judgments. Recording them would have manufactured the
   appearance of blinded measured acceptance, which this closeout refuses to
   attest. The record/freeze/compile machinery itself remains proven by the
   passing suite (`freeze_labels_spec.rb` freezes a full reference set and
   asserts the compiled report's measures and markdown end to end).
2. **Produced a failing-first fix.**
   `spec/services/facet_confidence/closeout_evaluation_packet_spec.rb` now
   fails against the leaky packet (asserting `input_revisions` keys equal the
   corpus case ids and that the serialized packet carries no case `expected`,
   `shape`, or `selection_rationale`), and
   `app/services/facet_confidence/closeout_evaluation_packet.rb:34` now keys
   revisions by case id only. The displayed Inbox values (revisions list,
   case count) are unchanged.
3. **Was re-verified live.** A fresh evaluation generation was then started
   through the fixed packet against the same closeout context (project
   `viamin/paid`, work item #4323, corpus `facet-confidence-corpus-v1`, digest
   `126b30c6b4796466f3057f78d0bedbb901e6fdb942ca14cafb7549ac396ecc0c`, no
   unresolved blockers). The emitted packet now carries only
   `{"FC-CORPUS-01":2, ..., "FC-CORPUS-08":2}`; the blinded case payloads
   expose exactly `direction, evidence, facet, id, label, thresholds`; and the
   evaluation sits in the `labeling` state with 0 labeled / 0 skipped,
   awaiting an **unexposed** judge.

## Measured acceptance state (why #4323 stays open)

The issue's first checklist item — run the versioned assessment corpus and
report false readiness, unnecessary clarification, human corrections, cost,
and rework — remains **not established**, in two separately-owned parts:

1. **Blinded reference judgments (#4596 workflow)**: shipped, defect fixed,
   and demonstrated live up to the labeling surface — but the only judge
   available to this session was invalidated by the packet leak above. An
   unexposed operator must resume the label-free evaluation generation left
   by this audit (or start an equivalent one), record the eight blinded
   judgments, freeze, and return the compiled evaluator report. No test
   fixture is attested as that measurement.
2. **Operator-executed rubric runs (#4573 machinery)**:
   `bin/facet-confidence-assessment-evaluation compile` against the frozen
   corpus still exits 2 — `pending operator input: every corpus case needs a
   non-failed assessment verdict` — because no `assessment_run` ledger events
   exist. The outcome worksheet
   (`docs/intent/facet-confidence/assessment-evaluation-2026-10-23/outcome-worksheet-2026-10-23.md`)
   correctly keeps every operator-derived measure `not established` and the
   tuning gate `blocked_incomplete_coverage`.

No new gap issue is filed: both parts are already owned — the recovery
note reserves the measured evaluation workflow for open #4596, and the rubric
runs for its operator runbook — and duplicating them is exactly what this
closeout must not do. When #4596 delivers the completed measured evaluation,
this closeout should be rerun against that evidence.

## Rollout guard and verification

The RDR-070 shadow-assessment guard is unchanged by this audit: readiness
release stays gated on the complete RDR-071 delivery path via
`FeatureIntents::ScopedReadiness` and `RunAdmission`; the 80/80 defaults are
untouched; no feature is enrolled, no active run is paused, and the evaluation
workflow itself changes no release policy (starting or completing it closes
nothing, per `FACET-CONFIDENCE-020`).

Environment: dependencies installed with `bundle install` and `yarn install
--frozen-lockfile`; databases prepared from `DATABASE_URL` via
`bin/rails db:prepare` (development and test). The live workflow execution ran
under the test encryption configuration with the production service objects,
the shipped frozen corpus, and the real `Issues::CloseoutStatus` blocker path
(reporting none). `bin/coherence-check.mjs` and the full focused re-run
results are recorded in the closeout PR.
