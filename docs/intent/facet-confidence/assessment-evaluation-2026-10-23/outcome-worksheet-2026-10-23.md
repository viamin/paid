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

On 2026-10-26, the shipped assessment path attempted every frozen case but no
provider in that environment served the pinned model. The eight attempts are
retained as provenance-valid `failed` `assessment_run` events in
[`ledger.jsonl`](ledger.jsonl); they are operational failures, not rubric
verdicts. Consequently, no operator-executed verdict run exists yet, and
`bin/facet-confidence-assessment-evaluation compile` correctly remains at
`pending operator input` (exit 2) until a provider serving
`claude-sonnet-4-6` runs the corpus.

No corpus run may release work while readiness-driven release stays gated on
the RDR-071 delivery path (RDR-070 rollout guard). The figures below are
policy-assessment measures of this frozen corpus, not calibrated probabilities.

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
| Corpus coverage | 0 / 8 cases | Eight `assessment_run` events are failed; verdict coverage requires a non-failed run |
| False readiness | not established | No completed verdicts; expected readiness band vs `assessment_run` |
| Unnecessary clarification | not established | No completed verdicts; expected decisive outcome vs `assessment_run` status |
| Human corrections | 0 cases (0.0% / 0 of 8) | No `correction` events |
| Assessment cost | 0 cents | Every recorded provider-unavailable attempt has `cost_cents: 0` |
| Downstream rework | 0 events / 0 cents | No `rework` events |
| Band divergences | not established | No completed scores to compare against expected bands |
| Operational failures | 8 cases (100.0% / 8 of 8) | One `assessment_run` with status `failed` for each corpus case |

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

**Tuning-gate outcome: `blocked_incomplete_coverage`.** Threshold or rubric
tuning proposals stay unevaluated until a provider serving the pinned model
produces a non-failed run for every case and the compiled outcome metrics
exist. The corrective action is to run the corpus through that provider, append
the verdict events, and mirror the resulting compiled worksheet here. The
80/80 defaults remain unchanged.
