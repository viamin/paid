# RDR-067 blinded shadow-mode evaluation operator runbook — 2026-10-13

This runbook is for the 2026-10-13 measured rollout run. It starts from a
frozen corpus commit and ends with the reviewer-run events appended by the
human operator. An agent may prepare and freeze the corpus, but it MUST NOT
create adjudication records or represent labels as independent operators.
`INTENT-CONFORMANCE-ROLLOUT-002` remains unmet until two distinct human
operators supply auditable, distinct provenance for their blinded
adjudications. The `shadow-run` step remains operator-driven and the CLI
intentionally defers it with `pending-human-input`.

## Freeze, then adjudicate

1. The corpus curator verifies each case against its linked approved design
   revision (the same `abe405ef…` revision for every case in this run)
   before freezing the manifest.
2. Commit the manifest file (`docs/intent/intent-conformance-rollout/shadow-evaluation-manifest-2026-10-13.yml`)
   and record its immutable Git commit SHA — that SHA is the
   `manifest_commit` every later event carries.
3. Before opening any case packet, the two named human operators and a
   potential third operator record their distinct, organization-authenticated
   identities in the rollout record. Each identity must be independently
   auditable; aliases, a shared bot account, and commits authored by the PR
   agent are not provenance. Every later event repeats the same
   `manifest_commit`.
4. Each primary human operator independently appends one `adjudication` event
   per case. The event carries their authenticated identity, a verdict of
   `accepted`, `material_drift`, or `uncertain`, a cited design claim, a
   reason, and an ISO-8601 timestamp. Preserve an auditable link from each
   event to that human's authenticated action. Do not proceed if the two
   actions cannot be distinguished.

## Tie-break and reviewer sequence

If the two primary verdicts agree, the case is adjudicated. If they differ,
the frozen third operator, who is not either primary operator,
independently reviews the same blinded packet and appends exactly one
tie-break. The ledger rejects a duplicated operator identity, a missing
tie-break, or more than one tie-break.

Only after every case has a complete adjudication may the shadow-run
operator invoke the shadow command. Before scheduling any case, the
operator must verify that `intent_conformance_shadow_review` is enabled and
that all of the following remain disabled for the named project:
`intent_conformance_enforcement`, `approved_intent_amendments`, scanner
blocker, Inbox escalation, amendment flow, and `VerifyAtMerge`. The run
record is appended only after the human records it and includes the
reviewer run ID, model, prompt digest, verdict timestamp, and cost.

## Metrics and promotion

Compile only after adjudications and reviewer events exist. The compiler
traces every metric to ledger events and prints `not established` for
missing evidence. It does not issue a promotion decision while any
promotion-rule input is missing. The 2026-10-13 worksheet will record
measures only after the independently provenanced adjudications exist; until
then, all adjudication- and reviewer-derived measures remain `not established`.
