---
parent: PAID
prefix: CHAT-TURN
---

# Low-Level Design: Chat Turn Recovery

Interactive chat turns have a durable lifecycle independent of a browser stream. A
`ChatTurn` is created for each persisted user message and records its current
state, last durable activity, classification, recovery count, and auditable
events. The lifecycle is `pending`, `streaming`, `completed`, `failed`,
`stalled`, or `abandoned`. A pending tool confirmation remains pending rather
than being called stalled.

`ChatSessions::StalledTurnSweepJob` scans streaming turns. It marks a turn
stalled only after the account-configured inactivity timeout and only when the
session is neither rate-limited nor awaiting a confirmation. The transition and
the explanatory system notice are committed together. The notice preserves the
transcript and states that no tool will be replayed automatically.

Recovery is an explicit, authorization-checked request. A row lock and one
attempt cap deduplicate concurrent requests. The recovery job rebuilds the
conversation from persisted messages and asks the model to continue; it does
not dispatch a stored tool call. Any newly proposed write remains subject to
the ordinary confirmation gate. Automatic retry is intentionally absent from
this slice until each eligible failure class has an idempotency contract.

Turn columns and `ChatTurnEvent` rows are queryable for stall classifications,
detection time, recovery requests/outcomes, and duplicate-prevention attempts.

| Decision | Rationale |
| --- | --- |
| Manual recovery only | A durable transcript is not proof that a partially dispatched external tool is idempotent. |
| Separate turn records | Session and browser state cannot express a per-user-message terminal conclusion or support queryable audit history. |
