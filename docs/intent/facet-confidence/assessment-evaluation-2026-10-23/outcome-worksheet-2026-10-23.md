# RDR-070 Facet-Confidence Assessment Outcome Worksheet — 2026-10-23

<!-- @spec FACET-CONFIDENCE-016 @spec FACET-CONFIDENCE-017 -->
<!-- @spec FACET-CONFIDENCE-018 -->

The frozen corpus
[`assessment-corpus-manifest-v1.yml`](../assessment-corpus-manifest-v1.yml)
(`facet-confidence-corpus-v1`, rubric `facet-confidence-v1`, model
`claude-sonnet-4-6`, thresholds 80/80) is the repository-visible versioned
corpus RDR-070 requires. It covers the eight required shapes: provisional
direction, explicit corrections, repeated agent suggestions, collaborator
disagreement, unknown intent with strong technical evidence, strong intent
with weak feasibility, research scope, and the 79/80 boundary.

The closeout executed the frozen corpus through the shipped assessment path on
2026-10-26. No configured provider served the pinned `claude-sonnet-4-6`
model, so all eight runs failed before returning a verdict. The append-only
[`ledger.jsonl`](ledger.jsonl) records those provider-unavailability failures
with the frozen corpus digest, rubric/model identities, and each case's input
evidence revision. These are operational failures, not model verdicts.

No corpus run may release work while readiness-driven release stays gated on
the RDR-071 delivery path (RDR-070 rollout guard). The failures establish no
calibrated probabilities and do not justify a threshold or rubric change.

## Corpus identity

| Control | Recorded state |
|---|---|
| Corpus version | `facet-confidence-corpus-v1` |
| Rubric / model | `facet-confidence-v1` / `claude-sonnet-4-6` (matches `FeatureIntents::AssessFacet`) |
| Thresholds | intent 80 / technical 80 (provisional policy defaults) |
| Case shapes | 8 required shapes, 8 cases, one per shape |
| Provenance per run | corpus version + digest, rubric, model, input evidence revision (ledger-validated) |
| Replay guard | identical case input rejected; re-runs require an advanced input revision plus a recorded correction |
| Evidence fidelity | completed runs must cite case evidence; corrections must be cited, superseded statements must not be |

Deterministic coverage independent of model output is held by the test suite:
`spec/lib/facet_confidence/assessment_corpus_ledger_spec.rb` validates the
committed corpus and ledger provenance;
`spec/lib/facet_confidence/assessment_outcome_report_spec.rb` proves the
metric computation (including parity with `ScopedReadiness` at the 79/80 and
80/80 boundary) against fixture ledgers; and
`spec/services/feature_intents/scoped_readiness_spec.rb` already proves the
79/80 boundary stays not ready in the admission path itself.

## Measures

| Measure | Result | Ledger evidence |
|---|---|---|
| Corpus coverage | 0 / 8 verdicts | all eight `assessment_run` events failed before a verdict |
| False readiness | not established | expected readiness band vs non-failed `assessment_run` |
| Unnecessary clarification | not established | expected decisive outcome vs non-failed `assessment_run` status |
| Human corrections | 0 (0.0% of corpus cases) | no `correction` events recorded |
| Assessment cost | 0 cents | every failed `assessment_run.cost_cents` is 0 |
| Downstream rework | 0 events / 0 cents | no `rework` events recorded |
| Band divergences | not established | no scored `assessment_run` exists to compare |
| Operational failures | 8 (100.0% of attempted runs) | every `assessment_run` has status `failed` |

A `failed` run is an operational (provider/runtime) failure, never an
assessment verdict: it is reported as an operational failure above and stays
out of the unnecessary-clarification, false-readiness, and band-divergence
measures, so provider outages cannot inflate or deflate assessment quality.

## Tuning gate

| Tuning rule | Outcome |
|---|---|
| Every corpus case has at least one recorded non-failed verdict | Not met — all eight provider calls failed |
| Tuning proposal cites false-readiness and unnecessary-clarification metrics | Not evaluable — no verdict metrics exist |
| Throughput-only justification | Never sufficient (enforced by the report's tuning gate) |

**Tuning-gate outcome: `blocked_incomplete_coverage`.** Threshold or rubric
tuning proposals stay unevaluated until the corpus runs return verdicts from
the pinned model and the compiled outcome metrics exist. The corrective action
is to rerun this unchanged frozen corpus in an environment whose provider
serves `claude-sonnet-4-6`; do not substitute another model, alter the rubric,
or change the 80/80 defaults.
