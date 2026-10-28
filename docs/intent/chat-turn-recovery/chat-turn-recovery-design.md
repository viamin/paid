---
parent: PAID
prefix: CHAT-TURN-RECOVERY
---

# Low-Level Design: Chat Turn Recovery

Interactive chat messages are durable, but a message sequence alone cannot say
whether a provider invocation is still running, waiting for a human, or stopped.
Each user-initiated turn therefore has a `ChatTurn` record with lifecycle state,
last durable activity, and a checkpoint message. A maintenance sweep marks only
inactive `pending`/`streaming` turns as `stalled`; it never fabricates an
assistant response or changes prior tool evidence.

The message stream identifier is a processing claim: exactly one worker may
move its turn from `pending` to `streaming`. Repeated delivery of the same
stream exits before tool dispatch. Confirmation resolution finds the turn from
the confirmed tool's originating user message, records its result as activity,
and completes that same turn only after a durable assistant reply is saved.

Pending write confirmations and sessions parked for a known provider rate limit
are intentional waits, so they remain active. An elapsed rate-limit window is
not a permanent exemption. The threshold is configured by
`CHAT_TURN_STALL_THRESHOLD_SECONDS` (ten minutes by default). A stalled turn writes an in-
transcript system notice that links to its last durable activity and states that
unfinished actions must not be assumed to have run. The first slice deliberately
does not auto-replay a turn: tool calls can have side effects, and replay needs
an explicit checkpoint/idempotency contract. A later recovery action must claim
the turn atomically, be authorization/revision aware, and require confirmation
where a model stop or tool replay is ambiguous.
