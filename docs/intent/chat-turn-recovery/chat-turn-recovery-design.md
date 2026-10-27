---
parent: PAID
prefix: CHAT-TURN-RECOVERY
---

# Chat Turn Recovery Design

Interactive chat records a durable `ChatTurn` for each user-initiated exchange.
The record owns lifecycle status, last durable activity, recovery count, and an
append-only event history while `ChatMessage` remains the transcript authority.

The detector only classifies `pending` and `streaming` turns whose durable
activity is older than `CHAT_TURN_STALL_THRESHOLD_SECONDS` (ten minutes by
default). Pending tool confirmations and
known provider rate-limit pauses are explicit non-stall states. Classification
persists a system notice in the transcript; it never fabricates an assistant
answer or changes the turn to successful.

Recovery is explicitly requested by an authorized user. A row lock atomically
claims a stalled turn before a recovery job runs, recording duplicate requests
instead of starting concurrent work. The resumed loop rebuilds only from the
persisted transcript checkpoint. It never replays an already persisted tool
result, and any new write tool follows the existing confirmation contract.

Automatic recovery is intentionally not enabled in this slice. It requires a
per-classification replay-safety contract and idempotency evidence; the
rate-limit recovery path remains separately owned by CHAT-API-017.
