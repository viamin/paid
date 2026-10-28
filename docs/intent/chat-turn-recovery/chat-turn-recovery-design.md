---
parent: PAID
prefix: CHAT-TURN-RECOVERY
---

# Low-Level Design: Chat Turn Recovery

## Purpose

An interactive chat turn must have a durable conclusion. Browser streaming is
delivery state, not evidence that the server completed a turn. Each accepted
send therefore owns a `ChatTurn` row linked to its session and user message.

## Lifecycle and detection

Turns move `pending → streaming → completed|failed|stalled|abandoned`.
`checkpointed_at` records durable user, tool, and terminal activity. A bounded
maintenance sweep locks overdue `pending`/`streaming` rows and marks them
`stalled`; it never infers success. The default threshold is 10 minutes and
can be configured with `CHAT_TURN_STALL_THRESHOLD_SECONDS`.

A pending confirmation, an explicit rate-limit pause, and terminal outcomes
are conclusions rather than stalls. The initial slice does not automatically
replay a stalled turn: preserving tool evidence is safer than duplicating a
side effect. Future automatic recovery must require an infrastructure failure
classification plus a checkpointed idempotency contract.

## Transcript and audit

Classification persists a system notice that names the preserved checkpoint
and states that no assistant conclusion was recorded. The notice is a durable
transcript event, so reconnecting clients cannot silently lose it. `ChatTurn`
stores classification time, last checkpoint, and recovery counters; these
fields are indexed for operational queries. A row lock and unique notice
creation make repeated sweeps idempotent.

## Decisions & Alternatives

| Decision | Alternatives considered | Rationale |
| --- | --- | --- |
| Separate turn record | Infer state from messages | A dedicated lifecycle is queryable and cannot mistake partial transcript evidence for completion. |
| No automatic replay in first slice | Replay the original prompt | Existing tools have no universal idempotency/revision contract; replay could duplicate a write. |
