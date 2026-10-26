# RDR-070 facet-confidence assessment evaluation — 2026-10-23

Tracks #4573 (RDR-070 remaining acceptance criterion; blocks final acceptance
of #4323). This directory holds the operator record for the versioned
facet-confidence assessment corpus evaluation.

The frozen corpus lives at
[`../assessment-corpus-manifest-v1.yml`](../assessment-corpus-manifest-v1.yml)
(`facet-confidence-corpus-v1`, rubric `facet-confidence-v1`, model
`claude-sonnet-4-6`). Every recorded assessment run must bind to the corpus
version and content digest, the rubric and model versions, and the input
evidence revision it assessed; `bin/facet-confidence-assessment-evaluation`
stamps and validates that provenance and rejects replays of identical case
input. The runs themselves are executed through the shipped assessment path by
`bin/rails "facet_confidence:corpus:run[<project-id>]"` and are recorded in
[`ledger.jsonl`](ledger.jsonl). The outcome worksheet at
[`outcome-worksheet-2026-10-23.md`](outcome-worksheet-2026-10-23.md) is the
repository-visible measure record; every operator-derived measure stays
`not established` until the operator produces verdict runs for every case.

No corpus run can release work: readiness-driven release remains gated on the
complete RDR-071 delivery path, and the 80/80 thresholds stay the provisional
policy defaults (RDR-070 rollout guard). Threshold or rubric tuning proposals
must cite the outcome metrics; `compile` blocks on incomplete coverage and a
throughput increase alone never justifies tuning.

## Operator runbook

Follow [`operator-runbook.md`](operator-runbook.md): run the corpus through the
shipped assessment path, which appends one `assessment_run` event with full
provenance per case, then append `correction`/`rework` events as humans
challenge or rework outcomes. Only when every case has a verdict run does
`bin/facet-confidence-assessment-evaluation compile` emit the outcome
worksheet with false readiness, unnecessary clarification, human corrections,
assessment cost, and downstream rework.
