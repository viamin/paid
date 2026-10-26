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

On 2026-10-26, the shipped assessment path attempted every frozen case. No
configured provider served the pinned `claude-sonnet-4-6` model, so the ledger
records eight `failed` operational runs and no assessment verdict. Each event
binds the corpus version and digest, rubric and model versions, and its frozen
input-evidence revision; no event is attributed to another model. The compiled
worksheet command correctly remains pending (`pending operator input`, exit
2) until a provider can produce a non-failed verdict for every case.

These numbers are policy assessments, not calibrated probabilities. No corpus
run may release work while readiness-driven release stays gated on the complete
RDR-071 delivery path (RDR-070 rollout guard), and the 80/80 defaults remain
unchanged.

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
| Corpus coverage | 0 / 8 verdict cases | all eight recorded runs are operational failures, not verdicts |
| False readiness | 0 (not established) | no completed/clarification/unknown verdicts |
| Unnecessary clarification | 0 (not established) | no completed/clarification/unknown verdicts |
| Human corrections | 0 (0.0% / 0 of 8 cases) | no `correction` events |
| Assessment cost | 0 cents | eight `assessment_run.cost_cents: 0` events |
| Downstream rework | 0 events / 0 cents | no `rework` events |
| Band divergences | 0 (not established) | no scored verdicts |
| Operational failures | 8 (100.0% / 8 runs) | every `assessment_run` status is `failed` |

A `failed` run is an operational (provider/runtime) failure, never an
assessment verdict: it is reported as an operational failure above and stays
out of the unnecessary-clarification, false-readiness, and band-divergence
measures, so provider outages cannot inflate or deflate assessment quality.

## Tuning gate

| Tuning rule | Outcome |
|---|---|
| Every corpus case has a non-failed assessment verdict | Not met — all eight recorded runs failed operationally |
| Tuning proposal cites false-readiness and unnecessary-clarification metrics | Not evaluable — metrics not established |
| Throughput-only justification | Never sufficient (enforced by the report's tuning gate) |

**Tuning-gate outcome: `blocked_incomplete_coverage`.** Threshold or rubric
tuning proposals stay unevaluated until an environment serving the pinned
model records verdicts for the corpus and the compiled outcome metrics exist.
The corrective action is to re-run the frozen corpus there; it is not to tune
the rubric or thresholds for throughput.
