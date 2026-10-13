# RDR-067 blinded shadow evaluation ledger — 2026-10-13

Tracks #4205. This directory is the append-only event record for the
2026-10-13 measured rollout run. The frozen corpus that adjudications,
reviewer runs, and resolutions must reference lives at
[`shadow-evaluation-manifest-2026-10-13.yml`](../shadow-evaluation-manifest-2026-10-13.yml)
and is bound to that commit's SHA (`manifest_commit`) plus a SHA-256 digest
of the manifest file (`manifest_digest`) recorded by
`bin/intent-conformance-shadow-evaluation append` itself. A replacement of
either value in any later commit is rejected by `validate`/`shadow-run`/
`compile`.

Each stage (freeze, each adjudication, each shadow run, each tie-break
resolution, each follow-up, each delivery event) MUST be introduced by its
own Git commit so the repository's own history proves the order of events.
Batched appends are rejected.

## Operator runbook

Follow [`operator-runbook.md`](operator-runbook.md): freeze and commit the
corpus, record an `operators_frozen` event first, then two independent
`adjudication` events per case, blind to reviewer output. If the two
adjudicators disagree, append exactly one third-operator tie-break. Only
after every case has a complete adjudication may the operator invoke
`bin/intent-conformance-shadow-evaluation shadow-run`; the CLI exits
`pending-human-input` until the human operator records reviewer runs, so
this PR records adjudications and leaves shadow_run events for the
operator-driven follow-up.

## Verification

`bin/intent-conformance-shadow-evaluation validate` checks ledger
self-consistency. `bin/intent-conformance-shadow-evaluation compile` produces
the aggregate worksheet only when the ledger passes `validate!` AND every
case has a corresponding `shadow_run` event. Until the operator appends
those reviewer events, `compile` exits `pending-human-input`. The
repository-visible worksheet at
[`shadow-evaluation-worksheet-2026-10-13.md`](../shadow-evaluation-worksheet-2026-10-13.md)
mirrors the same constraint.