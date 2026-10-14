# RDR-067 blinded shadow evaluation ledger — 2026-10-13

Tracks #4205. This directory will hold the append-only event record for the
2026-10-13 measured rollout run after qualifying human adjudications exist.
The frozen corpus that adjudications, reviewer runs, and resolutions must
reference lives at
[`shadow-evaluation-manifest-2026-10-13.yml`](../shadow-evaluation-manifest-2026-10-13.yml)
and is bound to that commit's SHA (`manifest_commit`) plus a SHA-256 digest
of the manifest file (`manifest_digest`) recorded by
`bin/intent-conformance-shadow-evaluation append` itself. A replacement of
either value in any later commit is rejected by `validate`/`shadow-run`/
`compile`.

Each stage (freeze, each adjudication, each shadow run, each tie-break
resolution, each follow-up, each delivery event) needs an auditable record.
For adjudications, that record MUST establish two distinct authenticated human
operators; Git event order alone does not prove human independence. Batched
appends are rejected.

## Operator runbook

Follow [`operator-runbook.md`](operator-runbook.md): freeze and commit the
corpus, then obtain blinded adjudications from two independently
authenticated human operators for every case. If the two adjudicators
disagree, obtain exactly one third-human tie-break. Only after every case has
a complete qualifying adjudication may the operator invoke
`bin/intent-conformance-shadow-evaluation shadow-run`; the CLI exits
`pending-human-input` until the human operator records reviewer runs, so
this PR records no qualifying adjudications and leaves the complete measured
rollout for the operator-driven follow-up.

## Verification

`bin/intent-conformance-shadow-evaluation validate` checks ledger
self-consistency, but it cannot by itself prove that operator labels represent
different humans. `bin/intent-conformance-shadow-evaluation compile` produces
the aggregate worksheet only when the ledger passes `validate!` AND every
case has a corresponding `shadow_run` event. Until independently authenticated
humans append qualifying adjudications and the operator appends reviewer
events, `compile` exits `pending-human-input`. The
repository-visible worksheet at
[`shadow-evaluation-worksheet-2026-10-13.md`](../shadow-evaluation-worksheet-2026-10-13.md)
mirrors the same constraint.
