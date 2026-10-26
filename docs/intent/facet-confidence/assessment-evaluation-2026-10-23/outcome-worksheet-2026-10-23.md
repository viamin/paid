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

On 2026-10-26, the assessment path attempted all eight cases but no provider
in that environment served the pinned model. The resulting eight `failed`
`assessment_run` events are retained in [`ledger.jsonl`](ledger.jsonl), each
bound to the corpus version/digest, rubric/model version, and its input
evidence revision. No verdict run exists yet: executing the rubric against
live model output remains an operator action
([`operator-runbook.md`](operator-runbook.md)), and no corpus run may release
work while readiness-driven release stays gated on the RDR-071 delivery path
(RDR-070 rollout guard). Until non-failed verdicts exist, quality measures
below stay not established — mirroring what
`bin/facet-confidence-assessment-evaluation compile` emits
(`pending operator input`, exit 2).

## Corpus identity

| Control | Recorded state |
|---|---|
| Corpus version | `facet-confidence-corpus-v1` |
| Rubric / model | `facet-confidence-v1` / `claude-sonnet-4-6` (matches `FeatureIntents::AssessFacet`) |
| Thresholds | intent 80 / technical 80 (provisional policy defaults) |
| Case shapes | 8 required shapes, 8 cases, one per shape |
| Provenance per run | corpus version + digest, rubric, model, input evidence revision (ledger-validated) |
| Replay guard | identical verdict input rejected; a failed provider attempt can retry frozen input; verdict re-runs require an advanced revision plus a recorded correction |
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
| Corpus coverage | 0 / 8 verdict cases | 8 failed `assessment_run` events retained; non-failed verdicts required |
| False readiness | not established | expected readiness band vs `assessment_run` |
| Unnecessary clarification | not established | expected decisive outcome vs `assessment_run` status |
| Human corrections | not established | `correction` events required |
| Assessment cost | not established (0 cents recorded for failed attempts) | `assessment_run.cost_cents` required |
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
| Every corpus case has at least one recorded run | Not met — operator runs absent |
| Tuning proposal cites false-readiness and unnecessary-clarification metrics | Not evaluable — metrics not established |
| Throughput-only justification | Never sufficient (enforced by the report's tuning gate) |

**Tuning-gate outcome: `blocked_incomplete_coverage`.** These are policy
assessments, not calibrated probabilities. Threshold or rubric tuning proposals
stay unevaluated until the operator records non-failed corpus verdicts and the
compiled outcome metrics exist; throughput does not justify a change. The
corrective action is to execute the runbook in an environment whose provider
serves `claude-sonnet-4-6`, then mirror the compiled worksheet here.
