# RDR-067 blinded shadow evaluation ledger

Tracks #4205. The issue remains open: this change supplies tooling only.

This directory contains scaffolding only. `adjudication-ledger.jsonl` is intentionally empty: it records no adjudications, reviewer runs, metrics, or promotion outcome.

Use the immutable corpus candidate inventory as a review packet source. Before the first adjudication, commit its final contents and record that commit SHA in every event's `manifest_commit`. Append one JSON object per line and commit the append; never alter or remove an existing line, and never batch multiple appends into a single commit — each stage (freeze, each adjudication, each shadow run) needs its own commit so Git history, not a repeated label, proves the order events happened in.

Supported event types are `operators_frozen`, `adjudication`, `shadow_run`, `resolution`, `follow_up`, and `delivery`. An adjudication has `case_id`, `operator`, `verdict` (`accepted`, `material_drift`, or `uncertain`), `cited_design_claim`, `reason`, `recorded_at`, and `manifest_commit`. Freeze operator identities first using an `operators_frozen` event with an `operators` array. The first two operators must differ. If their verdicts differ, append exactly one third, different operator's adjudication.

Every event also carries a `manifest_digest`, a SHA-256 of the manifest file's contents computed by the `append` command itself (never trust a caller-supplied value). `validate`/`shadow-run`/`compile` recompute the manifest's current digest and reject the ledger if any event's recorded digest no longer matches — this catches a manifest edited (or a case swapped in place) after adjudication while keeping the same `manifest_commit` label.

Matching labels and digests only prove the ledger is internally self-consistent *right now* — they do not prove the manifest commit actually predates the events, since all of that state could be fabricated after the fact in one sitting. `validate`/`shadow-run`/`compile` also verify this against the repository itself: `manifest_commit` must resolve to a real commit whose tree holds the exact manifest content the ledger recorded, the ledger must itself be committed, and each ledger-changing descendant commit must append exactly one event without changing or deleting an earlier line. A ledger that fails any of those checks is rejected even if every label and digest matches.

The command rejects incomplete adjudications, edits represented by duplicate event IDs, post-event manifest identities, manifest content that no longer matches what was adjudicated, reviewer events before complete adjudications, and ledgers whose manifest/event chronology is not backed by real Git history. `shadow-run` always exits pending-human-input today because this PR must not run reviews; `compile` is gated only on ledger completeness and emits values derived solely from ledger evidence.
