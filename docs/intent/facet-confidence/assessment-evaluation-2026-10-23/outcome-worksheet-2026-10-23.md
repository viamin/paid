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

On 2026-10-26, the operator executed the frozen corpus through the shipped
assessment path. Every one of the eight runs failed before a verdict because
the available provider did not serve the pinned `claude-sonnet-4-6` model.
The append-only [`ledger.jsonl`](ledger.jsonl) records those failures with the
frozen corpus, rubric, model, and input-evidence provenance. No corpus run may
release work while readiness-driven release stays gated on the complete RDR-071
delivery path (RDR-070 rollout guard).

The figures below are policy-assessment outcome measures, not calibrated
probabilities. They provide no basis to tune the rubric or either 80/80
default; `compile` remains `pending operator input` (exit 2) until a provider
can produce a non-failed verdict for every case.

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
| Corpus coverage | 0 / 8 cases | all eight `assessment_run` events failed before a verdict |
| False readiness | 0 (not established) | no verdict run exists to compare with expected readiness |
| Unnecessary clarification | 0 (not established) | no verdict run exists to compare with expected decisive outcomes |
| Human corrections | 0 (0.0%, 0 / 8) | no `correction` events recorded |
| Assessment cost | 0 cents | `assessment_run.cost_cents` across failed runs |
| Downstream rework | 0 events / 0 cents | no `rework` events recorded |
| Band divergences | 0 (not established) | no scores exist to compare with expected bands |
| Operational failures | 8 (100.0%, 8 / 8) | each `assessment_run` has status `failed` (`pinned_model_unavailable`) |

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
tuning proposals stay unevaluated until an environment whose provider serves
the pinned model produces corpus verdicts and the compiled outcome metrics
exist. The corrective action is to rerun the existing frozen corpus there,
append new provenance-complete events, and mirror the completed worksheet
here; it is not to change the rubric, model, thresholds, or release policy.
