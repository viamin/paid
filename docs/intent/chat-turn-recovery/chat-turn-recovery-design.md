---
parent: PAID
prefix: CHAT-TURN-RECOVERY
---

# Low-Level Design: Chat Turn Recovery

## Purpose

Every accepted chat request has a durable `ChatTurn`. The turn records its
lifecycle independently of transient browser streaming so an interrupted
request cannot look completed merely because the browser lost its connection.

## Lifecycle

Turns progress from `pending` to `streaming`, then to `completed`, `failed`,
`stalled`, or `abandoned`. `last_activity_at` is advanced only by durable
server-side checkpoints: the request row, persisted assistant/tool rows, and
terminal transitions. A pending tool confirmation and a recorded rate-limit
pause are deliberate waiting states, so the detector does not classify them as
stalled.

The maintenance sweep locks and classifies only stale non-terminal turns.
Classification appends a durable system notice to the transcript; it preserves
the associated message IDs and whether any write tool completed. A stalled
turn is never a success.

## Recovery and audit

Recovery requires an explicit, authorized user action. The recovery request is
serialized by the turn lock and records its actor, time, and outcome. The
first release has no automatic replay: a recovery is always an explicit user
confirmation because a partial turn may have invoked a side-effecting tool.
Automatic recovery remains opt-in for a future failure classification only
after the relevant tool declares an idempotency/checkpoint contract.

## Decisions & Alternatives

| Decision | Rationale | Alternative rejected |
| --- | --- | --- |
| Persist a separate turn record | Message rows describe evidence, not a terminal conclusion or recovery lease. | Inferring a turn solely from message ordering would make concurrent and partial turns ambiguous. |
| Explicit-only recovery initially | A provider retry could repeat a mutation whose external result is unknown. | Blanket automatic retry violates the confirmation boundary. |
