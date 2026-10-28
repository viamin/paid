---
parent: PAID
prefix: CHAT-TURN
---

# Low-Level Design: Chat Turn Recovery

## Purpose

A persisted user message is not evidence that a chat turn completed. Every submitted
message therefore owns a durable `ChatTurn` lifecycle record. The record is the
authoritative conclusion for the exchange while transcript rows remain the evidence.

## Detection

`ChatSessions::SendMessage` starts a turn after it persists the user message and
updates its activity timestamp whenever it persists evidence. A maintenance sweep
marks only `pending` and `streaming` turns stalled after the configurable
`CHAT_TURN_STALL_AFTER_SECONDS` threshold. It excludes runner rate-limit pauses and
pending tool confirmations, which have established recovery/approval paths.

The sweep uses a row lock and state re-check, making repeated cron ticks idempotent.
It records detection time, classification, and whether a completed tool result exists.

## User-facing outcome and recovery

A stalled turn creates a durable transcript notice. It explicitly says that no final
answer was recorded, preserves partial evidence, and warns against replaying actions.
The first release deliberately has no automatic tool replay: ambiguous stops and
completed side-effecting tools require user review. Future automatic recovery must
resume from a checkpoint and prove the tool's idempotency contract before opt-in.
