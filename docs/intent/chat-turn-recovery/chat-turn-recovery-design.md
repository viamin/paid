---
parent: PAID
prefix: CHAT-TURN
---

# Low-Level Design: Durable Chat Turn Recovery

## Purpose

Chat transcript rows alone cannot distinguish a completed assistant turn from a
worker that stopped after persisting a user message or tool evidence. This
segment records a durable turn lifecycle so the transcript never silently
represents an unfinished turn as successful.

## Lifecycle

`ChatTurn` begins `streaming` before the worker invokes the chat loop. Each
persisted message advances its durable checkpoint. A normal return becomes
`completed`; classified errors become `failed`; and an inactive `streaming`
turn becomes `stalled` after ten minutes. `pending` and `abandoned` are
reserved lifecycle states for admission and an explicit future cancellation.

Pending tool confirmations and a known provider-rate-limit recovery window are
intentional pauses, not stalls. Detection holds the turn row lock while
transitioning it and creating exactly one transcript notice, so duplicate
sweeps cannot create duplicate notices.

## Recovery boundary

The first slice detects and explains uncertainty only. It never replays a tool
or fabricates an assistant response. The notice directs the user to inspect
preserved results and explicitly continue; a later recovery slice must resume
from the stored checkpoint and may auto-retry only a classified infrastructure
failure with an idempotency contract.

## Observability

The turn row records state, detection time, terminal time, checkpoint activity,
and failure class. The detector emits a structured `chat_turn.stalled` event.

## Traceability

* HLD: `docs/high-level-design.md` — No silent stops.
* Related: `docs/intent/api-mode-chat/` and `docs/intent/chat-tool-confirmation/`.
