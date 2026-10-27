---
parent: PAID
prefix: CHAT-TURN
---

# Low-Level Design: Chat Turn Recovery

Chat transport state is transient, while a user message and tool evidence are durable. A `ChatTurn` joins those facts into one auditable lifecycle: `pending`, `streaming`, `awaiting_confirmation`, `completed`, `failed`, `stalled`, or `abandoned`. Each transition writes a `ChatTurnEvent` so classification and outcome remain queryable.

The message service creates or reuses the turn for its durable user message, marks it streaming, and marks it completed only after a final assistant message was persisted. A write-tool pause moves it to `awaiting_confirmation`; this state is deliberately excluded from stall detection. Known job errors move the turn to `failed` rather than leaving a misleading active state.

`ChatSessions::DetectStalledTurnsJob` runs every five minutes. It marks only `pending` or `streaming` turns whose durable activity exceeds the configurable `CHAT_TURN_STALL_THRESHOLD_SECONDS` (ten minutes by default). It persists an in-transcript notice explaining that saved tool evidence is preserved but later work is unknown. The notice never claims success.

Automatic replay is intentionally not enabled in this slice. A persisted tool call does not by itself prove replay safety or idempotency. The notice directs users to begin a new message after reviewing results; a future resume action must introduce a checkpoint and explicit per-tool replay contract before it can be automatic.
