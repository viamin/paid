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
input. The outcome worksheet at
[`outcome-worksheet-2026-10-23.md`](outcome-worksheet-2026-10-23.md) is the
repository-visible measure record; every operator-derived measure stays
`not established` until a non-failed verdict exists for every case. The
2026-10-26 attempts are retained as operational failures because no provider
served the pinned model; they are not assessment verdicts.

No corpus run can release work: readiness-driven release remains gated on the
complete RDR-071 delivery path, and the 80/80 thresholds stay the provisional
policy defaults (RDR-070 rollout guard). Threshold or rubric tuning proposals
must cite the outcome metrics; `compile` blocks on incomplete coverage and a
throughput increase alone never justifies tuning.

## Operator runbook

Follow [`operator-runbook.md`](operator-runbook.md): for each corpus case,
replay the frozen evidence through the facet-confidence assessment path,
append one `assessment_run` event with full provenance, then append
`correction`/`rework` events as humans challenge or rework outcomes. Only
when every case has a run does
`bin/facet-confidence-assessment-evaluation compile` emit the outcome
worksheet with false readiness, unnecessary clarification, human corrections,
assessment cost, and downstream rework.
