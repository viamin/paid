---
parent: PAID
prefix: CHAT-TURN-RECOVERY
---

# Low-Level Design: Chat Turn Recovery

## Scope

Paid owns a durable lifecycle for each user-initiated chat turn. A turn begins
when its user message persists and records `pending`, `streaming`,
`completed`, `failed`, `stalled`, or `abandoned`. A terminal assistant message
completes the turn; a pending tool confirmation leaves it pending rather than
stalled. Failures already returned by the execution path are failed, never
successful.

The periodic detector examines only `streaming` turns with no durable activity
for the configured timeout. A declared `long_running_until` checkpoint is not
stalled before that deadline. Detection atomically changes the lifecycle state
and appends one system notice, preserving all existing messages and tool rows.

## Recovery and audit

The notice explains that completed tool results are preserved while work after
the final durable checkpoint is unknown. Resume is an explicit, authorized
user action. It atomically claims a stalled turn before enqueueing a fresh
continuation from its original user-message checkpoint; concurrent or repeated
requests fail without another enqueue. The rebuilt transcript contains prior
tool results, so recovery does not replay completed tool calls. Any new
side-effecting call follows the existing confirmation policy.

Automatic replay is deliberately not enabled in this slice: no tool has yet
declared and verified the idempotency/reconciliation contract required for it.
The turn records classification, detection, recovery count and actor metadata
so stall and recovery outcomes remain queryable.
