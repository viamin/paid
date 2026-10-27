---
parent: root
prefix: CHAT-TURN
---

# Chat turn recovery

## Purpose

Chat turns must reach a durable, user-visible conclusion. A missing worker completion must not be represented as a successful assistant response.

## Design

`ChatTurn` records the user-message checkpoint and lifecycle. A bounded cron sweep marks active turns with no durable activity as `stalled`, except turns awaiting explicit tool confirmation. It preserves the transcript and inserts a system notice. This first slice does not automatically replay any tool or model call; recovery remains an explicit follow-up because existing tool calls may have side effects.

## Decisions & Alternatives

| Decision | Rationale | Alternative |
| --- | --- | --- |
| Persist a turn beside messages | Makes a missing terminal outcome queryable independently of browser state. | Infer state from transcript on every read. |
| No automatic replay | Existing tools do not yet declare an idempotency/checkpoint replay contract. | Blanket infrastructure retries. |
