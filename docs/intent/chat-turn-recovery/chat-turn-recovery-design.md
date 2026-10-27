---
parent: PAID
prefix: CHAT-TURN-RECOVERY
---

# Low-Level Design: Chat Turn Recovery

## Purpose

Each submitted chat message owns one durable `ChatTurn`. The turn records its
server-side lifecycle independently of browser streaming state so an interrupted
worker cannot look like a successful response.

## Lifecycle and detection

Turns progress through `pending`, `streaming`, `completed`, `failed`,
`stalled`, or `abandoned`. A scheduled sweep classifies only `pending` and
`streaming` turns whose durable activity heartbeat is older than the configured
threshold (ten minutes by default). Pending tool confirmation and an active,
known rate-limit pause are intentional waits and remain outside classification.

The detector locks and rechecks each candidate before it changes state. It
persists a transcript notice with the turn identifier and whether a
side-effecting tool result was recorded. The original user message, tool cards,
and partial assistant evidence remain unchanged.

## Audit and recovery boundary

`ChatTurnEvent` records lifecycle outcomes with account-scoped query indexes.
The first slice records failure and stalled classification but does not perform
automatic replay. That is intentional: automatic recovery needs a per-tool
idempotency/checkpoint contract. A future explicit recovery flow must claim a
stalled turn atomically, be authorization and revision aware, and require user
confirmation whenever a model stop is ambiguous or a side-effecting tool may
have run.

## Decisions & Alternatives

| Decision | Rationale | Alternative rejected |
| --- | --- | --- |
| Persist a turn separate from `ChatMessage` | Lifecycle and audit queries should not depend on parsing transcript metadata. | Derive stalled state from browser streaming flags; those are lost on disconnect. |
| Start with detection and notice only | It closes the silent-stop gap without implying a tool call is safe to replay. | Blanket automatic retry; this can duplicate mutations. |
