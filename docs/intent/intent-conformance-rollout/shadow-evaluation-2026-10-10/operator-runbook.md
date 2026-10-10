# RDR-067 blinded shadow-mode evaluation operator runbook

This runbook starts from a pending corpus. It must not be used to infer any evaluation result from the candidate labels or invalidated October worksheets.

## Freeze, then adjudicate

1. A corpus curator verifies each candidate against its linked approved design revision and replaces this candidate inventory with the final corpus. Selection must be by the content of the PR relative to that design—not PR date, commit adjacency, or a history block.
2. Commit the final corpus manifest. Record its immutable Git commit SHA.
3. Before opening any case packet, append an `operators_frozen` event naming the two primary operators and a potential third operator. Every later event repeats that manifest SHA. The tool rejects any other manifest identity after the first adjudication.
4. Give each primary operator only the case packet: PR metadata, base/head diff, and approved design revision. Do not give them the ledger's `shadow_run` events, an existing `IntentConformanceVerdict`, reviewer prompts, model output, or a worksheet.
5. Each operator independently appends one `adjudication` event for each case. It must contain their identity, a verdict of `accepted`, `material_drift`, or `uncertain`, a cited design claim, a reason, and an ISO-8601 timestamp. An append is final; corrections require a separately documented, new corpus run rather than editing or deleting the event.

## Tie-break and reviewer sequence

If the two primary verdicts agree, the case is adjudicated. If they differ, a frozen third operator, who is not either primary operator, independently reviews the same blinded packet and appends exactly one tie-break. The ledger rejects a duplicated operator identity, a missing tie-break, or more than one tie-break.

Only after every case has a complete adjudication may the shadow-run operator invoke the shadow command. Before scheduling any case, the operator must verify that `intent_conformance_shadow_review` is enabled and that all of the following remain disabled for the named project: `intent_conformance_enforcement`, `approved_intent_amendments`, scanner blocker, Inbox escalation, amendment flow, and `VerifyAtMerge`. The run record is appended only after the human records and includes the reviewer run ID, model, prompt digest, verdict timestamp, and cost.

## Metrics and promotion

Compile only after adjudications and reviewer events exist. The compiler must trace every metric to ledger events and print `not established` for missing evidence. It must not issue a promotion decision while any promotion-rule input is missing. The current ledger is deliberately empty, so all commands that would advance this process must stop with `pending human input`.
