---
parent: root
prefix: CHAT-TURN
---

# Chat turn recovery design

## Purpose

Chat transport state is transient, but a chat request and its outcome must be durable. A missing terminal outcome is visible uncertainty, never a successful response.

## Design

`ChatTurn` records one client transport key, its user message, lifecycle, last durable activity, completed side effects, and recovery claim. A maintenance sweep marks only inactive `pending` or `streaming` turns as `stalled`; pending confirmations and rate-limit pauses remain intentional non-terminal states. Stalling adds one in-transcript system notice without changing or inventing transcript content.

Recovery is row-locked and reuses the original transport key and persisted conversation checkpoint. It is available only when no side-effecting tool completed; turns with side effects remain visible for explicit human review. This first slice deliberately does not auto-replay tools.

## Decisions & alternatives

| Decision | Rationale |
| --- | --- |
| Dedicated `ChatTurn` row rather than inferred message ranges | Lifecycle, timing, recovery claims, and audit fields are queryable and survive transport disconnects. |
| Default to no automatic replay | Tool calls can mutate external state; a durable checkpoint alone is not an idempotency contract. |
