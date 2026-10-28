---
parent: PAID
prefix: CHAT-TURN
---

# Low-Level Design: Chat Turn Recovery

Each user message owns one durable `ChatTurn`. It begins `pending`, moves to
`streaming`, and ends `completed`, `failed`, `stalled`, or `abandoned`.
Durable message and tool persistence renews its activity checkpoint. A
maintenance sweep marks only inactive pending/streaming turns stalled. Pending
tool confirmation and provider rate-limit pauses are intentional waiting states
and are excluded.

Stalling is transactional and creates one in-transcript system notice. The
notice preserves the transcript and explicitly says that remaining work is
unknown. Automatic replay is deliberately absent from this first slice: a
recovery that could repeat a side effect requires a future explicit,
idempotency-aware confirmation flow.
