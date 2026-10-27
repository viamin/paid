---
parent: PAID
prefix: CHAT-TURN-RECOVERY
---

# Low-Level Design: Chat Turn Recovery

Interactive chat streaming is transport state, not evidence that a request
completed. Each submitted request therefore owns one durable `ChatTurn` tied
to its user message. The turn records a lifecycle (`pending`, `streaming`,
`completed`, `failed`, `stalled`, or `abandoned`), its last durable activity,
classification, and bounded recovery attempts.

`ChatSessions::ProcessMessageJob` transitions the turn as it starts and ends.
Persisted assistant and tool rows refresh the turn's activity checkpoint.
The detector only stalls pending or streaming turns that have exceeded the
configured timeout and have neither a pending confirmation nor a known
rate-limit pause. It creates an in-transcript system notice that describes the
preserved evidence and makes clear that no completion was inferred.

Recovery is deliberately manual in this first release. A recovery request is
claimed under the turn row lock and only re-enqueues a turn whose completed
tool rows are all read-only. A turn with any completed write tool remains
stalled for operator/user review; a new request must not blindly replay it.
The existing confirmation protocol remains the only authority to dispatch a
write tool. `ChatTurn` rows make detection, recovery requests, outcomes, and
duplicate recovery claims queryable without overloading transcript text.

| Decision | Alternatives | Rationale |
| --- | --- | --- |
| Store turns separately from messages | Infer a turn from timestamps and metadata | A separate lifecycle makes an incomplete request queryable and allows locking recovery without mutating transcript evidence. |
| Manual recovery first | Automatically replay all infrastructure failures | Tool replay is unsafe until each tool has an explicit checkpoint/idempotency contract. |
| Exempt confirmations and rate limits | Apply one wall-clock timeout | These states already have durable, actionable owners and are not silent stops. |
