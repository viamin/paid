---
parent: PAID
prefix: CHAT-TURN
---

# Low-Level Design: Chat Turn Recovery

## Purpose

Each persisted user message starts a durable `ChatTurn`. A turn records its
last durable checkpoint and lifecycle (`pending`, `streaming`, `completed`,
`failed`, `stalled`, or `abandoned`) so a dropped stream cannot look like a
successful reply. This implements the HLD's no-silent-stops tenet (#4680).

## Detection

`ChatTurns::StallSweepJob` runs every five minutes. It considers only pending
or streaming turns with no durable activity for `CHAT_TURN_STALL_THRESHOLD`
(15 minutes by default). Turns awaiting a tool confirmation, and turns already
ended by a provider, budget, or rate-limit failure, are excluded. The sweep
atomically marks a candidate stalled and persists one transcript notice.

## Recovery and safety

Recovery is opt-in. A Resume action requires an explicit confirmation and
reuses the original user-message checkpoint; it never creates a second user
request. It is allowed only when no approved write-tool result exists and no
tool confirmation is pending. A row lock transitions the turn to streaming,
which deduplicates concurrent or repeated requests. Automatic replay is not
enabled in this slice: tools have not yet declared idempotency contracts.

## Observability

`ChatTurn` is the query surface: classification, detection timestamp, recovery
attempt count, outcome, checkpoint, and duplicate-prevention count are durable
columns. Structured lifecycle logs carry the turn and session IDs.
