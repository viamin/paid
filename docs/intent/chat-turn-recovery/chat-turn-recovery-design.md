# Chat Turn Recovery Design

prefix: CHAT-TURN-RECOVERY
parent: high-level-design

Interactive chat persists a `ChatTurn` for each submitted user request. The
turn is a durable lifecycle record, separate from transient browser streaming:
`pending`, `streaming`, `completed`, `failed`, `stalled`, and `abandoned`.

`ChatSessions::DetectStalledTurns` runs from a bounded, singleton GoodJob
sweep. It marks only active turns whose durable activity is older than the
configured threshold. Pending tool confirmations are an intentional human
wait state and are excluded. A stalled turn is never represented as successful:
the detector preserves the existing transcript and writes a system notice that
names the unknown conclusion and links to the request.

This first slice deliberately has no automatic replay. Persisted tool results
cannot prove that an external side effect is safe to repeat. Future recovery
must require a checkpoint and tool-specific idempotency contract before an
infrastructure classification can opt into a bounded retry; ambiguous stops
remain user-confirmed.

## Decisions & Alternatives

| Decision | Rationale | Alternative |
| --- | --- | --- |
| Use a separate turn record | State and audit fields must be queryable without overloading message metadata. | Infer turns from transcript ordering. |
| Do not auto-replay in the first slice | Partial tool evidence is insufficient to safely repeat a side effect. | Retry every failed or stale job. |
