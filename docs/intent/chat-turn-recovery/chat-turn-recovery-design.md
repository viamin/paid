---
parent: PAID
prefix: CHAT-TURN-RECOVERY
---

# Low-Level Design: Chat Turn Recovery

## Purpose

Chat turns have durable messages but previously had no durable conclusion. A
worker or connection failure could leave partial tool evidence without saying
whether the request was still running, failed, or safe to retry.

## Lifecycle

`ChatTurn` records the request identity, initiating message, actor, durable
activity timestamp, and one lifecycle state: `pending`, `streaming`,
`completed`, `failed`, `stalled`, or `abandoned`. A stream identifier makes a
background delivery idempotent. The initiating user message and all partial
tool evidence remain in `ChatMessage`; the turn never fabricates an assistant
answer.

The send path creates or resumes its turn before model work and refreshes its
durable activity as messages are persisted. A normal answer, or a deliberate
wait for tool confirmation, completes the initiating turn. Known errors fail
the turn. A rate-limit pause remains owned by the existing rate-limit recovery
path and completes its initiating turn rather than appearing stalled.

## Detection and transcript notice

A singleton maintenance sweep finds only `pending` and `streaming` turns whose
last durable activity is older than `CHAT_TURN_STALL_THRESHOLD` (default 10
minutes). It locks each row before transitioning it to `stalled`, which makes
repeated sweeps and concurrent workers idempotent. The transition persists one
non-collapsed system notice naming the preserved activity and explaining that
completion is unknown. Pending tool confirmations and already terminal turns
are excluded.

## Recovery safety

The first slice deliberately does not automatically replay a stalled turn.
The notice directs the user to review the preserved transcript and confirmation
cards before sending another request. Automatic replay is deferred until each
tool exposes a durable idempotency/checkpoint contract; a stalled turn is never
treated as successful and an ambiguous model stop always needs explicit user
judgment.

## Observability

Lifecycle transitions are queryable from `chat_turns`; the state, timestamps,
failure classification, recovery count, and notice metadata form the audit
trail. Structured logs record classification and the detector's outcome.
