---
parent: PAID
prefix: CHAT-TURN-RECOVERY
---

# Low-Level Design: Chat Turn Recovery

## Purpose

Every accepted chat request has a durable `ChatTurn` record. The record makes
the request's lifecycle visible independently of the browser stream, so a
worker loss cannot leave a persisted user message looking successful.

## Lifecycle

A turn moves from `pending` to `streaming`, then to `completed`, `failed`,
`stalled`, or `abandoned`. A completed turn may have the outcome
`awaiting_confirmation`; that is a deliberate human pause, not a stall.
`last_activity_at` is updated for durable messages and lifecycle transitions.

A maintenance sweep selects non-terminal turns whose activity is older than
the configurable `chat_turn_stall_threshold` (default 10 minutes). It excludes
pending tool confirmations and sessions paused for a provider rate limit.
The detector claims each row atomically, marks it stalled, and persists a
system notice. It records detection metadata on the turn, preserving all
messages and tool evidence.

## Recovery

The first slice does not replay turns automatically. A stalled notice asks the
user to review the preserved transcript and submit a new request. This is
intentional: no tool has an idempotency/checkpoint contract suitable for
automatic replay yet. Future recovery must atomically claim a turn, validate
the actor and turn revision, and resume from a checkpoint; it must require
explicit confirmation if a side-effecting tool might be repeated.

## Observability

Turn state, classification, detection time, recovery-attempt count and whether
any completed tool calls were side-effecting are persisted and queryable. State
transitions are structured logged with the turn and session IDs.

## Decisions & Alternatives

| Decision | Rationale |
| --- | --- |
| Use a dedicated turn record rather than infer from messages | The lifecycle and detection timestamp must remain queryable even when streaming events are lost. |
| Start with manual recovery | Message history alone is not a replay-safe checkpoint for arbitrary tools. |
