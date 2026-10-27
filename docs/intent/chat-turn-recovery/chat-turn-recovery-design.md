---
parent: PAID
prefix: CHAT-TURN-RECOVERY
---

# Low-Level Design: Chat Turn Recovery

## Purpose

Each submitted chat message owns a durable `ChatTurn`.  A turn records its
lifecycle and latest durable activity independently of browser streaming so a
lost worker or client cannot make a partially executed turn look successful.

## Detection and safety

The watchdog considers only `pending` and `streaming` turns whose activity has
been quiet for `ChatTurn::STALL_AFTER`.  It excludes a session paused for a
known rate limit and turns with pending tool confirmation; both are deliberate
wait states.  Under a row lock it marks the remaining turns `stalled`, records
the classification and detection time, and appends one durable transcript
notice.  Repeated sweeps are idempotent.

The initial recovery surface is deliberately conservative: a stalled notice
preserves the user message and completed tool evidence and directs users to
pending confirmations.  It never replays a tool call.  A later resume may only
be enabled after a tool declares an idempotency/checkpoint contract.

## Observability

`chat_turns` stores classification, detection/recovery timestamps and a JSON
audit trail.  These fields make stalled-turn, abandoned-turn, recovery and
duplicate-prevention queries possible without parsing logs.
