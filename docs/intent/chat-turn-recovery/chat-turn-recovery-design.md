---
parent: PAID
prefix: CHAT-TURN
---

# Low-Level Design: Chat Turn Recovery

## Purpose

Chat turns are durable units beginning with a persisted user message. A turn records its lifecycle so an interrupted execution is never rendered as success.

## Behavior

The watchdog marks inactive pending/streaming turns `stalled` after a configurable threshold. It excludes provider rate-limit pauses and pending human confirmations. Classification persists an in-transcript system notice describing the unknown outcome and directing the user to review preserved tool evidence before explicitly continuing. The initial slice intentionally performs no automatic replay: tool replay requires a checkpoint and idempotency contract per tool.

## Traceability

*HLD:* `docs/high-level-design.md` → No silent stops; Observable everything.
