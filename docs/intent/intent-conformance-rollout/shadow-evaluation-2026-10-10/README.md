# RDR-067 blinded shadow evaluation ledger

Tracks #4205. The issue remains open: this change supplies tooling only.

This directory contains scaffolding only. `adjudication-ledger.jsonl` is intentionally empty: it records no adjudications, reviewer runs, metrics, or promotion outcome.

Use the immutable corpus candidate inventory as a review packet source. Before the first adjudication, commit its final contents and record that commit SHA in every event's `manifest_commit`. Append one JSON object per line; never alter or remove an existing line.

Supported event types are `operators_frozen`, `adjudication`, `shadow_run`, `resolution`, `follow_up`, and `delivery`. An adjudication has `case_id`, `operator`, `verdict` (`accepted`, `material_drift`, or `uncertain`), `cited_design_claim`, `reason`, `recorded_at`, and `manifest_commit`. Freeze operator identities first using an `operators_frozen` event with an `operators` array. The first two operators must differ. If their verdicts differ, append exactly one third, different operator's adjudication.

The command rejects incomplete adjudications, edits represented by duplicate event IDs, post-event manifest identities, and reviewer events before complete adjudications. It intentionally exits pending-human-input for `shadow-run` and `compile` today because this PR must not run reviews or emit evaluation values.
