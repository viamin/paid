---
parent: PAID
prefix: CHAT-TURN-RECOVERY
---

# Chat Turn Recovery

Paid records each Action Cable chat submission as a durable `ChatTurn`. A turn
starts `pending`, becomes `streaming` when its job starts, and finishes as
`completed`, `failed`, `stalled`, or `abandoned`. The turn keeps its stream
identity, most recent durable activity, initiating actor, user message, and
failure classification; it never infers success from a disconnected browser.

A maintenance sweep classifies only inactive `pending` or `streaming` turns as
`stalled`. It excludes a current provider rate-limit pause and pending write
confirmation, both of which have existing durable recovery paths. Classification
is serialized by a row lock, writes a visible system notice in the transcript,
and records whether approved write tools may already have completed.

The first slice deliberately does not replay a stalled turn. A notice directs
the user to inspect preserved tool cards and explicitly send a new message;
automatic replay is unsafe until individual tools declare checkpoint and
idempotency contracts. The durable status and audit metadata provide the
checkpoint for a later, authorization-aware resume flow.

| Decision | Rationale |
| --- | --- |
| Persist a turn row instead of browser streaming state | A browser disconnect cannot establish whether server work completed. |
| Make stall detection opt-out for rate limits and confirmations | Those states are known, visible waits rather than silent stops. |
| Do not auto-retry | Existing tool confirmation does not establish replay idempotency. |
