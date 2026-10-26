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

On 2026-10-26, the C70 closeout attempted every frozen case through the
shipped assessment path. No provider in that environment served the pinned
`claude-sonnet-4-6` model, so all eight attempts are recorded in
[`ledger.jsonl`](ledger.jsonl) as failed operational runs. They are not model
verdicts, and therefore do not establish assessment quality or release work.
Readiness-driven release remains gated on the complete RDR-071 delivery path
(RDR-070 rollout guard).

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
| Corpus coverage | 0 / 8 cases | eight failed `assessment_run` events; no verdict run |
| False readiness | not established | no completed verdicts to compare |
| Unnecessary clarification | not established | no non-failed assessment verdicts |
| Human corrections | 0 (0.0% (0 / 8 cases)) | no `correction` events |
| Assessment cost | 0 cents | each failed `assessment_run.cost_cents` is 0 |
| Downstream rework | 0 events / 0 cents | no `rework` events |
| Band divergences | not established | no scored assessment verdicts |
| Operational failures | 8 (100.0%, 8 / 8 runs) | all `assessment_run` events have status `failed` |

A `failed` run is an operational (provider/runtime) failure, never an
assessment verdict: it is reported as an operational failure above and stays
out of the unnecessary-clarification, false-readiness, and band-divergence
measures, so provider outages cannot inflate or deflate assessment quality.

## Tuning gate

| Tuning rule | Outcome |
|---|---|
| Every corpus case has at least one recorded non-failed verdict run | Not met — all eight recorded runs are provider failures |
| Tuning proposal cites false-readiness and unnecessary-clarification metrics | Not evaluable — no verdict metrics are established |
| Throughput-only justification | Never sufficient (enforced by the report's tuning gate) |

**Tuning-gate outcome: `blocked_incomplete_coverage`.** These are policy
assessments, not calibrated probabilities. Threshold or rubric tuning proposals
stay unevaluated until an environment serving the pinned model produces
non-failed verdict runs and the compiled outcome metrics exist. The 80/80
defaults remain unchanged; the corrective action is to re-run the frozen
corpus where `claude-sonnet-4-6` is available, preserve these failure events,
and append new valid runs rather than altering the corpus, rubric, or
thresholds.
