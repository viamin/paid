---
parent: PAID
prefix: CHAT-TURN-RECOVERY
---

# Low-Level Design: Chat Turn Recovery

## Purpose

Every accepted chat turn has a durable lifecycle record. A missing terminal
assistant response is visible as a stalled turn, never treated as success.
The first release detects and explains stalled turns while preserving all
messages and tool evidence; it does not automatically replay tools.

## Lifecycle and detection

`ChatTurn` records `pending`, `streaming`, `completed`, `failed`, `stalled`,
or `abandoned`, plus durable activity and append-only event rows. The detector
runs every five minutes and locks each candidate before transitioning it. It
only stalls a pending/streaming turn with no activity for 15 minutes. Pending
write-tool confirmation is intentional waiting and is excluded. Explicit
provider, budget, and rate-limit paths remain failures or their existing
durable notices rather than stalls.

## Visibility and recovery safety

Classification creates an in-transcript system notice naming the preserved
partial state and uncertainty. A user may explicitly retry a stalled turn;
the row lock plus revision prevents concurrent retries. It warns that retry
can repeat work. The first slice deliberately offers no automatic replay:
tool idempotency and a checkpoint/resume contract must be established per tool
before infrastructure recovery is enabled. `ChatTurnEvent` makes detection,
user action, and outcomes queryable.

## Decisions & Alternatives

| Decision | Alternatives | Rationale |
| --- | --- | --- |
| Persist a turn separate from messages | Infer state from transcript rows | A transcript cannot distinguish a terminal answer from an interrupted process. |
| Disable automatic replay initially | Retry every infrastructure failure | Existing tool contracts do not prove replay safety. |
