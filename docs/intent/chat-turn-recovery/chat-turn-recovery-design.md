---
parent: PAID
prefix: CHAT-TURN-RECOVERY
---

# Low-Level Design: Chat Turn Recovery

## Purpose

Every persisted user message starts one durable `ChatTurn`. A turn is pending,
streaming, completed, failed, stalled, or abandoned. The turn's durable
checkpoint is advanced only when the server persists evidence; browser stream
state is never evidence of completion.

## Stall detection

The maintenance sweep selects only pending/streaming turns with no checkpoint
for the configured ten-minute threshold. It skips turns awaiting a write-tool
confirmation and turns carrying an explicit future `expected_completion_at`
lease, so a human decision and a declared long operation are not misclassified.
The row is locked before it changes to `stalled`, making concurrent sweep
executions and repeated observations idempotent. A stalled turn receives a
durable system message; it never receives a fabricated assistant response.

## Recovery boundary

This first slice deliberately does not auto-replay a stalled turn. Existing
rate-limit recovery remains its own classified, in-place path. Replaying a
turn that has persisted tool activity can repeat an external side effect, so a
future resume action must hold an explicit user confirmation, use the turn's
persisted checkpoint, and require a replay-safe/idempotency contract per tool.

## Observability

`ChatTurn` stores lifecycle state, checkpoint time, stall detection time,
failure classification, and recovery-attempt count in queryable columns. The
sweep emits a structured event with detected turn IDs.

## References

- `docs/high-level-design.md` — No silent stops
- `docs/intent/api-mode-chat/` — chat persistence and tool loop
- `docs/intent/chat-tool-confirmation/` — mutation confirmation authority
