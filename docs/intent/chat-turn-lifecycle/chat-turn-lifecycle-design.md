# Chat Turn Lifecycle

## Purpose

Chat turns have a durable outcome independent of browser streaming state, so a persisted user request never silently appears successful when execution stops before a final assistant response.

## Design

`ChatTurn` records the request's stream identity, user-message checkpoint, lifecycle state, last durable activity, terminal classification, and detection timestamp. The `CHAT_TURN_STALL_THRESHOLD_SECONDS` environment setting controls the detector threshold and defaults to 15 minutes when absent or invalid. A scheduled detector locks eligible `pending` or `streaming` rows after that threshold and changes only still-eligible rows to `stalled`. Every persisted message in the active turn refreshes the durable activity checkpoint. Pending write-tool confirmations, known provider rate limits, budget exhaustion, and explicit failures remain owned by their existing terminal paths.

The detector writes and broadcasts a system transcript notice rather than an assistant response. It states that the visible messages and tool results remain evidence, that no completion was recorded, and directs the user to inspect confirmations before starting a new request. It snapshots whether a completed side-effecting tool result exists so a retry cannot be mistaken for safe replay. A delayed worker cannot restart a classified turn. This first slice does not replay a stalled turn: automatic replay needs a per-tool idempotency contract and an explicit recovery checkpoint.

## Decisions & Alternatives

| Decision | Alternatives | Rationale |
| --- | --- | --- |
| Persist a `ChatTurn` row | Infer turns from message timestamps | Explicit lifecycle state is queryable and lockable, unlike heuristic transcript boundaries. |
| Stall only after inactivity and outside pending confirmation | Treat every unfinished request as failed | Confirmations and known pauses are actionable state, not silent failures. |
| No automatic replay in this slice | Retry every infrastructure failure | Replaying tool calls without idempotency can duplicate side effects. |
