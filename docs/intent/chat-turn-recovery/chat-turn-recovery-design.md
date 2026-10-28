---
parent: PAID
prefix: CHAT-TURN
---

# Low-Level Design: Chat Turn Recovery

Each submitted user message owns one durable `ChatTurn`. Its lifecycle is
`pending`, `streaming`, `completed`, `failed`, `stalled`, or `abandoned`.
Messages created while the turn runs are associated with it, making the last
persisted activity a server-side fact rather than a browser streaming detail.

A five-minute sweep marks only inactive `streaming` turns stalled after the
configurable model constant threshold. It excludes rate-limit pauses and
pending tool confirmations, which are deliberate waiting states. Classification
persists a system transcript notice; no missing assistant response is invented.

The initial safety boundary is deliberately conservative: a stalled turn that
has any persisted tool result is never replayed automatically. Future recovery
must require an idempotency/checkpoint contract before it may replay tools.

