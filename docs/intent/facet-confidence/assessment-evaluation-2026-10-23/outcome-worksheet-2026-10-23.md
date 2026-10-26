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

The corpus is executed through the shipped assessment path by
`bin/rails "facet_confidence:corpus:run[<project-id>]"`, and the recorded runs
live in [`ledger.jsonl`](ledger.jsonl). Executing the rubric against live
model output is an operator action
([`operator-runbook.md`](operator-runbook.md)), and no corpus run may release
work while readiness-driven release stays gated on the RDR-071 delivery path
(RDR-070 rollout guard). Until verdict runs exist, every operator-derived
measure below stays not established — mirroring what
`bin/facet-confidence-assessment-evaluation compile` emits
(`pending operator input`, exit 2).

## C70 audit execution — 2026-10-26

The C70 closeout audit ([#4323](https://github.com/viamin/paid/issues/4323))
executed the whole corpus through the shipped assessment path. All eight cases
were attempted and all eight ended as **operational failures**: the assessment
provider never returned a verdict, so no score was produced and no certainty
was recorded.

| Observation | Recorded state |
|---|---|
| Cases executed | 8 / 8 |
| Verdict runs recorded | 0 / 8 (every recorded run is an operational failure) |
| Operational failures | 8 (`assessment_run` events with status `failed`, no scores, no cited evidence) |
| Reason | The frozen corpus pins rubric `facet-confidence-v1` under model `claude-sonnet-4-6`. In the audit environment no provider served that model: the Anthropic-compatible transport authenticated against `api.anthropic.com` and the environment's key was rejected (`invalid x-api-key`), and the CLI path reported the pinned model as unknown to the configured endpoint. |
| Effect on the measures | None are inflated or deflated: a failed run is excluded from false readiness, unnecessary clarification, and band divergences, and is reported as an operational failure. |
| Correction | The shipped ledger no longer lets an operational failure consume the input revision, so the same cases can be measured once a provider serving the pinned model is available. |

The recorded runs are repository-visible evidence, not a measurement result:
false readiness, unnecessary clarification, human corrections, assessment cost,
downstream rework, and band divergences remain **not established** until a
provider serving `claude-sonnet-4-6` produces verdict runs for all eight
cases.

## Corpus identity

| Control | Recorded state |
|---|---|
| Corpus version | `facet-confidence-corpus-v1` |
| Rubric / model | `facet-confidence-v1` / `claude-sonnet-4-6` (matches `FeatureIntents::AssessFacet`) |
| Thresholds | intent 80 / technical 80 (provisional policy defaults) |
| Case shapes | 8 required shapes, 8 cases, one per shape |
| Provenance per run | corpus version + digest, rubric, model, input evidence revision (ledger-validated) |
| Replay guard | identical case input rejected for verdict runs; an operational failure is not a verdict and does not consume the input revision; re-runs require an advanced input revision plus a recorded correction |
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
| Corpus coverage | 0 / 8 verdict runs (8 / 8 cases attempted) | `assessment_run` events required |
| False readiness | not established | expected readiness band vs `assessment_run` |
| Unnecessary clarification | not established | expected decisive outcome vs `assessment_run` status |
| Human corrections | not established | `correction` events required |
| Assessment cost | not established | `assessment_run.cost_cents` required |
| Downstream rework | not established | `rework` events required |
| Band divergences | not established | expected bands vs `assessment_run` scores |
| Operational failures | 8 (audit run of 2026-10-26; no verdict produced) | `assessment_run` status `failed` |

A `failed` run is an operational (provider/runtime) failure, never an
assessment verdict: it is reported as an operational failure above and stays
out of the unnecessary-clarification, false-readiness, and band-divergence
measures, so provider outages cannot inflate or deflate assessment quality.

## Tuning gate

| Tuning rule | Outcome |
|---|---|
| Every corpus case has at least one verdict run | Not met — only operational failures are recorded |
| Tuning proposal cites false-readiness and unnecessary-clarification metrics | Not evaluable — metrics not established |
| Throughput-only justification | Never sufficient (enforced by the report's tuning gate) |

**Tuning-gate outcome: `blocked_incomplete_coverage`.** Threshold or rubric
tuning proposals stay unevaluated until the operator records the corpus verdict
runs and the compiled outcome metrics exist; the corrective action is to run
`bin/rails "facet_confidence:corpus:run[<project-id>]"` in an environment
whose provider serves the pinned rubric model, and to mirror the compiled
worksheet here.
