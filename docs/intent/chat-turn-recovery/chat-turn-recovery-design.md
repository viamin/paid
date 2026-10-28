---
parent: PAID
prefix: CHAT-TURN-RECOVERY
---

# Low-Level Design: Chat Turn Recovery

## Purpose

An interactive chat transcript must never imply that a user request completed
when server-side work stopped without a terminal result. `ChatTurn` is the
durable lifecycle record for one persisted user message. It keeps the original
transcript and records progress independently of the browser's transient
streaming state.

## Lifecycle and detection

A turn moves from `pending` to `streaming`, then to `completed`, `failed`,
`awaiting_confirmation`, `rate_limited`, `stalled`, or `abandoned`. Persisting any message for
the turn advances its activity timestamp. A scheduled, singleton sweep marks
only `pending` and `streaming` turns whose durable activity has exceeded the
configured `ChatTurn::STALL_THRESHOLD` as `stalled`.

`awaiting_confirmation` is deliberately excluded: a pending tool confirmation
is a human pause, not a stalled automation. Rate-limited work is likewise
handled by its existing durable pause and resume flow. The detector locks the
turn before transition, making repeated sweeps idempotent.

## Transcript and recovery boundary

When a turn becomes stalled, Paid writes one durable system notice into its
existing transcript. The notice identifies the last durable activity and
states that any remaining model or tool work is unknown. It links to an
awaiting confirmation when one exists, but never fabricates an assistant
answer or claims a tool succeeded.

This first slice intentionally offers no automatic replay. A stalled turn may
contain an already-completed side effect, so retrying the original prompt or
tool call is unsafe without a tool-specific idempotency/checkpoint contract.
Future recovery may resume only from a recorded checkpoint, must be
authorization and revision aware, and must claim a single recovery attempt
before dispatch.

## Observability

`ChatTurn` stores lifecycle state, classification, detection time, last durable
activity, and terminal timestamps. These fields are indexed for operational
queries and preserve the durable evidence required to distinguish completed,
paused, failed, and stalled work.
