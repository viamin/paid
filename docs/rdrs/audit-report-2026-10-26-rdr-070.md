# RDR-070 Closeout Audit — 2026-10-26

- **RDR**: [RDR-070: Facet Confidence and Adaptive Clarification](RDR-070-facet-confidence-and-clarification.md)
- **Closeout issue**: [#4323](https://github.com/viamin/paid/issues/4323) (C70)
- **Umbrella**: [#4309](https://github.com/viamin/paid/issues/4309) — **Tracks #4309; this audit does not close the umbrella.**
- **Follows**: [RDR Closeout Checklist](closeout-checklist.md)
- **Status decision**: **Partially Implemented**

This audit compares every RDR-070 acceptance criterion with the shipped code,
the focused tests that were run in this session, and the recorded corpus
measurement. Closed child issues were not used as implementation evidence. It
records what shipped, what is still missing, and the two focused gap issues
that own the remainder.

## 1. Acceptance evidence

| RDR-070 criterion | Shipped evidence | Test evidence | Result |
| --- | --- | --- | --- |
| Independent bounded intent and technical judgments, with unknown distinct from a score | `app/models/feature_intent_facet_assessment.rb:14` (scores bounded to `0..100`, nullable), `app/services/feature_intents/assess_facet.rb:105` (`known_score?`), `db/migrate/20261017141954_create_feature_intent_facet_confidence_records.rb:91-92` (database bounds) | `spec/models/feature_intent_facet_assessment_spec.rb`; `spec/services/feature_intents/assess_facet_spec.rb` (unknown intent keeps `intent_score` nil) | Satisfied |
| Attributable, revisioned evidence and asynchronous assessment through `agent_harness` | `app/services/feature_intents/ingest_facet_evidence.rb:33-37` (revision advance), `app/services/feature_intents/schedule_facet_assessment.rb:15`, `app/services/feature_intents/assess_facet.rb:34` (harness call), `app/jobs/feature_intents/assess_facet_job.rb` | `spec/services/feature_intents/ingest_facet_evidence_spec.rb`, `spec/services/feature_intents/assess_facet_spec.rb`, `spec/services/feature_intents/assess_facet_concurrent_evidence_spec.rb` | Satisfied |
| Corrections supersede prior evidence; disagreement clarifies rather than votes | `app/services/feature_intents/challenge_facet_assessment.rb:24-25` (correction supersedes the earlier statement), `app/services/feature_intents/assess_facet.rb:114` (rubric: a clear correction supersedes, collaborators conflict → clarification) | `spec/services/feature_intents/challenge_facet_assessment_spec.rb`; `spec/services/feature_intents/assess_facet_spec.rb:58` (collaborator conflict stays unresolved) | Satisfied |
| Adaptive comparative clarification accepts conditional, both/neither, and free-text answers | `app/services/chat_sessions/build_system_prompt.rb:233` | `spec/services/chat_sessions/build_system_prompt_spec.rb` | Satisfied |
| Explicit preferences retain an explicit statement, scope, provenance, and authorized lifecycle operations | `app/models/explicit_preference.rb:18-20,28-47`, `app/services/explicit_preferences/persist.rb`, `app/services/explicit_preferences/update.rb`, `app/services/explicit_preferences/delete.rb`, `app/mcp/tools/*explicit_preference.rb` | `spec/models/explicit_preference_spec.rb`, `spec/services/explicit_preferences/*_spec.rb`, `spec/mcp/tools/*explicit_preference_spec.rb` | Satisfied |
| Per-issue material prerequisite map and no vacuous readiness | `app/models/feature_intent_issue_prerequisite_mapping.rb`, `app/models/feature_intent_issue_prerequisite.rb`, `app/services/feature_intents/scoped_readiness.rb:38-51` | `spec/models/feature_intent_issue_prerequisite_mapping_spec.rb`, `spec/models/feature_intent_issue_prerequisite_spec.rb`, `spec/services/feature_intents/scoped_readiness_spec.rb:46` (an empty completed mapping is not ready) | Satisfied |
| Separate configurable 80/80 thresholds, unknown failure, no averaging, and research-scope handling | `app/services/feature_intents/scoped_readiness.rb:63-75` (per-axis comparison, no average), `db/migrate/20261016034711_add_facet_confidence_thresholds_to_projects.rb`, `app/services/feature_intents/scoped_readiness.rb:44-48` (only the mapped prerequisites are required, so a research issue is judged on its investigation scope) | `spec/services/feature_intents/scoped_readiness_spec.rb:25` (exact 80/80 passes), `:53` (79/80 fails on either axis), `:63` (out-of-range scores fail), `:83` (missing/pending/superseded fail visibly), `:142` (research scope) | Satisfied |
| Builder context exposes both scores, provenance categories, and no synchronous display-time LLM | `app/services/feature_intents/admitted_intent_context.rb`, `app/services/chat_sessions/build_system_prompt.rb:143` | `spec/services/feature_intents/admitted_intent_context_spec.rb`, `spec/services/chat_sessions/build_system_prompt_spec.rb` | Satisfied |
| Versioned representative assessment corpus with per-run provenance and outcome measures | `docs/intent/facet-confidence/assessment-corpus-manifest-v1.yml` (8 required shapes), `lib/facet_confidence/assessment_corpus_ledger.rb:292-298` (rubric/model binding), `lib/facet_confidence/assessment_outcome_report.rb:21-42` (measures), `bin/facet-confidence-assessment-evaluation` | `spec/lib/facet_confidence/assessment_corpus_ledger_spec.rb`, `spec/lib/facet_confidence/assessment_outcome_report_spec.rb`, `spec/bin/facet_confidence/assessment_evaluation_cli_spec.rb` | Satisfied as machinery; **measured verdict outcomes not established** (section 2) |
| The corpus is executable through the shipped assessment path (added by this audit) | `app/services/facet_confidence/assessment_corpus_runner.rb`, `app/services/facet_confidence/assessment_corpus_case.rb`, `lib/tasks/facet_confidence.rake` | `spec/services/facet_confidence/assessment_corpus_runner_spec.rb` (6 examples) | Satisfied |
| Measured false readiness, unnecessary clarification, human corrections, cost, and rework reported for the corpus | `docs/intent/facet-confidence/assessment-evaluation-2026-10-23/ledger.jsonl` (8 recorded operational failures), `docs/intent/facet-confidence/assessment-evaluation-2026-10-23/outcome-worksheet-2026-10-23.md` | `bin/facet-confidence-assessment-evaluation compile` → `pending operator input` (exit 2) | **Gap** — no verdict run exists (section 3) |
| Blinded reference judgments for every corpus case, recorded through the maintainer's session | `app/services/facet_confidence/closeout_evaluation/record_label.rb`, `app/services/facet_confidence/closeout_evaluation/freeze_labels.rb`, `app/services/facet_confidence/closeout_evaluation/compile_report.rb` | `spec/services/facet_confidence/closeout_evaluation/record_label_spec.rb`, `spec/services/facet_confidence/closeout_evaluation/freeze_labels_spec.rb`, `spec/requests/projects/facet_confidence_evaluations_spec.rb` | Flow shipped; **no recorded judgment set** (section 3) |

## 2. Numeric and policy findings

`FeatureIntents::ScopedReadiness` admits a prerequisite only when each known,
finite score lies in `0..100` and independently meets its project threshold.
The focused spec proves that 80/80 passes, that either 79/80 combination
fails, that an out-of-range or malformed score fails, and that a missing,
pending, superseded, or unknown assessment is visibly not ready
(`spec/services/feature_intents/scoped_readiness_spec.rb:25,53,63,83`). This
is deterministic policy enforcement, not score calibration.

The 80/80 defaults remain **provisional decision thresholds, not calibrated
probabilities and not a guarantee of successful delivery**. The audit found no
evidence that any score is tuned to raise throughput, and it adds no tuning:
the corpus tuning gate stays `blocked_incomplete_coverage` until the measured
verdict metrics exist (`lib/facet_confidence/assessment_outcome_report.rb:41`).
Because the measured verdict metrics do not exist yet, no threshold or rubric
change can even be evaluated today, and none is proposed.

## 3. The corpus run and what it did not establish

The corpus was executed through the shipped assessment path with
`bin/rails "facet_confidence:corpus:run[<project-id>]"`, which materializes
each frozen case as production facet records inside a rolled-back transaction
and runs `FeatureIntents::AssessFacet` over them through `agent_harness`.

| Observation | Recorded state |
| --- | --- |
| Cases executed | 8 / 8 |
| Verdict runs recorded | 0 / 8 |
| Operational failures recorded | 8 (`assessment_run` events with status `failed`, no scores, no cited evidence) |
| Reason | The frozen corpus pins rubric `facet-confidence-v1` under model `claude-sonnet-4-6`. No provider in the audit environment serves that model: the Anthropic-compatible transport authenticated against `api.anthropic.com` and the environment's key was rejected (`invalid x-api-key`), so every case recorded `Assessment unavailable (AgentHarness::AuthenticationError)`; the CLI path reported the pinned model as unknown to the configured endpoint. |
| Consequence | False readiness, unnecessary clarification, human corrections, assessment cost, downstream rework, and band divergences remain **not established**. The compiled report refuses to present them (`pending operator input`, exit 2). |

Two properties of the shipped machinery were confirmed by that execution and
are preserved in the code:

- A failed run is an operational failure, never an assessment verdict. It
  stays out of the false-readiness, unnecessary-clarification, and
  band-divergence measures, so a provider outage cannot inflate or deflate
  assessment quality.
- A run served by a different model than the corpus pins is refused rather
  than attributed (`app/services/facet_confidence/assessment_corpus_runner.rb:64-69`;
  the shipped ledger enforces the same binding at
  `lib/facet_confidence/assessment_corpus_ledger.rb:297-298`).

One bounded correction was required to keep the measurement executable: an
operational failure used to consume the case's input revision, so a provider
outage left the frozen corpus permanently unmeasurable (a re-run at the same
input was refused as a replay, and the frozen corpus has no correction to
offer). A failed run produces no verdict and no scores, so it can neither
inflate certainty nor consume the revision a later verdict run advances from.
`lib/facet_confidence/assessment_corpus_ledger.rb:341-370` now separates the
verdict revision from the recorded one, and
`spec/lib/facet_confidence/assessment_corpus_ledger_spec.rb` covers both the
replay guard for verdict runs and the retry after an operational failure.

## 4. Remaining gaps and ownership

Two required acceptance items are still unmet. Each has a focused owner, so
this audit files no duplicate work and no catch-all gap issue.

- **Measured verdict outcomes for the frozen corpus** — the corpus needs a
  provider serving the pinned rubric model `claude-sonnet-4-6`; the executed
  audit run recorded eight operational failures instead. The runner and the
  ledger are in place, so the remaining step is the execution itself.
- **Recorded blinded reference judgments** — the reference-judgment flow
  (#4596) is shipped, but no judgment set exists for this corpus. The
  judgments must be recorded through the authenticated maintainer's session;
  an agent may navigate and prepare, but agent-authored judgments would not be
  independent human validation, and the corpus expectations must not be reused
  as the judge's own answer.

## 5. Rollout guard

The RDR-070 shadow-assessment guard is unchanged: no old feature is enrolled,
no historical answer is reinterpreted as numerically certain, and no active
run is paused because evidence or thresholds changed. Readiness-driven release
stays gated on the complete RDR-071 delivery path, and this audit neither
enables delivery nor changes the 80/80 defaults. The corpus runner creates its
synthetic records only inside a rolled-back transaction, so a measurement never
reaches the readiness path.

## 6. Verification run

Executed in this session against PostgreSQL (`DATABASE_URL` service) with the
focused suites for the three RDR-069–071 segments:

```text
bundle exec rspec \
  spec/models/feature_intent_facet_assessment_spec.rb \
  spec/models/feature_intent_facet_evidence_spec.rb \
  spec/services/feature_intents/assess_facet_spec.rb \
  spec/services/feature_intents/assess_facet_concurrent_evidence_spec.rb \
  spec/services/feature_intents/ingest_facet_evidence_spec.rb \
  spec/services/feature_intents/challenge_facet_assessment_spec.rb \
  spec/services/feature_intents/scoped_readiness_spec.rb \
  spec/services/feature_intents/release_issue_spec.rb \
  spec/services/feature_intents/run_admission_spec.rb \
  spec/services/feature_intents/complete_forward_work_spec.rb \
  spec/services/feature_intents/complete_forward_work_concurrent_first_findings_spec.rb \
  spec/services/explicit_preferences/ spec/services/facet_confidence/ \
  spec/lib/facet_confidence/ spec/bin/facet_confidence/ \
  spec/requests/projects/facet_confidence_evaluations_spec.rb \
  spec/migrations/create_facet_confidence_evaluations_spec.rb
```

Result: **195 examples, 0 failures.** The question-exploration,
confidence-driven-delivery, and intent-conformance segments were re-run
separately in this session and passed as well (**574 examples, 0 failures**),
and the corpus runner's own suite passes (**6 examples, 0 failures**).
`bin/facet-confidence-assessment-evaluation validate` reports the committed
ledger as `valid`, and `compile` honestly reports `pending operator input`.

`bin/coherence-check.mjs` was run for the LID structural checks; the new
`FACET-CONFIDENCE-022` claim is defined in
`docs/intent/facet-confidence/facet-confidence-specs.md` and referenced from
the runner and its spec. The checker also reports pre-existing
repository-wide reverse orphans and stale arrow signals outside this closeout's
scope.

## 7. Closure decision

**Do not close [#4323](https://github.com/viamin/paid/issues/4323).** The
durable facet-confidence, clarification, preference, and readiness contracts
are shipped and verified by running tests, and the versioned corpus with its
provenance and outcome machinery is shipped. The measured verdict outcomes and
the recorded reference judgments do not exist, so RDR-070 remains **Partially
Implemented** and the closeout keeps its two focused gap issues as explicit
prerequisites.

**Tracks #4309.** This audit does not close the umbrella. The umbrella
[#4309](https://github.com/viamin/paid/issues/4309) is currently closed in
GitHub, which the
[2026-10-22 umbrella audit](audit-report-2026-10-22-human-centered-inbox-epic.md)
recorded as premature while required gaps remain; reopening it is the umbrella
owner's correction, not this closeout's, and it is flagged here so the
correction is not lost.
