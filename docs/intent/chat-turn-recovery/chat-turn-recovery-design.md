---
parent: PAID
prefix: CHAT-TURN-RECOVERY
---

# Low-Level Design: Chat Turn Recovery

## Purpose

Interactive chat must never leave a persisted request with partial activity and
no durable conclusion. A `ChatTurn` is the server-owned lifecycle record for a
single user request. It preserves the stream identity, its last durable
activity, and a terminal outcome independently of the browser connection.

## Lifecycle and detection

A turn begins `pending`, becomes `streaming` when its job starts, and ends as
`completed`, `failed`, `stalled`, or `abandoned`. The sweep considers only
pending or streaming turns whose `last_activity_at` is older than the
configurable threshold. It locks each candidate before transition, making
repeated sweeps safe.

Pending tool confirmation and a known provider rate-limit pause are excluded:
both have an explicit, durable next action and are not unknown stops. A stalled
turn records its detection time and creates an in-transcript system notice. The
notice preserves the request and partial tool evidence and states that no
completion is inferred.

## Recovery boundary

This first slice deliberately creates no automatic replay. A future recovery
may resume only from a persisted checkpoint, only after proving the unfinished
work is idempotent, and must deduplicate concurrent requests with the turn row
lock. Ambiguous/model stops and any turn with a completed side-effecting tool
require explicit user confirmation.

## Observability

The lifecycle record is the queryable audit trail for classification,
detection, recovery attempts, and outcome. Structured logs use the stable
`chat_turn.*` message namespace.
