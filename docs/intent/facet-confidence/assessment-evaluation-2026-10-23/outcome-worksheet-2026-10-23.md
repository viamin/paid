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

On 2026-10-26, the C70 closeout ran each frozen case through the shipped
assessment path. The provider did not serve the pinned rubric model
`claude-sonnet-4-6`, so all eight attempts are recorded as `failed`
operational events in [`ledger.jsonl`](ledger.jsonl); none is an assessment
verdict. A provider environment that serves the pinned model must record a new
baseline run before verdict-derived measures can be compiled. No corpus run
may release work while readiness-driven release stays gated on the RDR-071
delivery path (RDR-070 rollout guard).

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
| Corpus coverage | 0 / 8 verdicts | all eight `assessment_run` events are operational failures |
| False readiness | not established | expected readiness band vs `assessment_run` |
| Unnecessary clarification | not established | expected decisive outcome vs `assessment_run` status |
| Human corrections | not established | `correction` events required |
| Assessment cost | 0 cents observed | failed `assessment_run.cost_cents` total |
| Downstream rework | not established | `rework` events required |
| Band divergences | not established | expected bands vs `assessment_run` scores |
| Operational failures | 8 / 8 attempts (100.0%) | each case's `assessment_run` status is `failed` |

A `failed` run is an operational (provider/runtime) failure, never an
assessment verdict: it is reported as an operational failure above and stays
out of the unnecessary-clarification, false-readiness, and band-divergence
measures, so provider outages cannot inflate or deflate assessment quality.

## Tuning gate

| Tuning rule | Outcome |
|---|---|
| Every corpus case has at least one recorded run | Not met — operator runs absent |
| Tuning proposal cites false-readiness and unnecessary-clarification metrics | Not evaluable — metrics not established |
| Throughput-only justification | Never sufficient (enforced by the report's tuning gate) |

**Tuning-gate outcome: `blocked_incomplete_coverage`.** These are policy
assessments, not calibrated probabilities. Threshold or rubric tuning
proposals stay unevaluated until a provider serving `claude-sonnet-4-6`
produces the eight verdict runs and the compiled outcome metrics exist;
throughput is never a sufficient reason to tune. The 80/80 defaults remain
unchanged.
