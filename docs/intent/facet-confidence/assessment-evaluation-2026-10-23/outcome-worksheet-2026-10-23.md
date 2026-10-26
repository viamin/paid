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

On 2026-10-26, the shipped assessment path attempted every frozen corpus case.
No provider in that environment served the pinned model
`claude-sonnet-4-6`, so all eight attempts were recorded as operational
failures in [`ledger.jsonl`](ledger.jsonl). No assessment verdict exists. The
attempts do not release work: readiness-driven release remains gated on the
complete RDR-071 delivery path (RDR-070 rollout guard).

## Corpus identity

| Control | Recorded state |
|---|---|
| Corpus version | `facet-confidence-corpus-v1` |
| Rubric / model | `facet-confidence-v1` / `claude-sonnet-4-6` (matches `FeatureIntents::AssessFacet`) |
| Thresholds | intent 80 / technical 80 (provisional policy defaults) |
| Case shapes | 8 required shapes, 8 cases, one per shape |
| Corpus digest | `126b30c6b4796466f3057f78d0bedbb901e6fdb942ca14cafb7549ac396ecc0c` |
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
| Corpus coverage | 0 / 8 verdicts (8 / 8 attempts) | all attempts failed before a verdict |
| False readiness | not established | expected readiness band vs `assessment_run` |
| Unnecessary clarification | not established | expected decisive outcome vs `assessment_run` status |
| Human corrections | not established | `correction` events required |
| Assessment cost | 0 cents | `assessment_run.cost_cents` (no model invocation completed) |
| Downstream rework | not established | `rework` events required |
| Band divergences | not established | expected bands vs `assessment_run` scores |
| Operational failures | 8 (100.0% of 8 attempts) | `assessment_run` status `failed` |

A `failed` run is an operational (provider/runtime) failure, never an
assessment verdict: it is reported as an operational failure above and stays
out of the unnecessary-clarification, false-readiness, and band-divergence
measures, so provider outages cannot inflate or deflate assessment quality.

## Tuning gate

| Tuning rule | Outcome |
|---|---|
| Every corpus case has at least one recorded verdict | Not met — all eight attempts failed before a verdict |
| Tuning proposal cites false-readiness and unnecessary-clarification metrics | Not evaluable — metrics not established |
| Throughput-only justification | Never sufficient (enforced by the report's tuning gate) |

**Tuning-gate outcome: `blocked_incomplete_coverage`.** The 80/80 defaults and
the rubric are unchanged. Threshold or rubric tuning proposals stay
unevaluated until a provider serves the pinned model, every case has a
non-failed verdict, and the compiler can produce the outcome measures. The
recorded figures are policy assessments, not calibrated probabilities.
