---
parent: PAID
prefix: CHAT-TURN-RECOVERY
---

# Low-Level Design: Chat Turn Recovery

## Purpose

A chat message is not evidence that its turn completed. Each submitted user
message therefore owns a durable `ChatTurn` with a lifecycle of `pending`,
`streaming`, `completed`, `failed`, `stalled`, or `abandoned`. The turn is the
audit boundary for liveness, recovery, and user-visible outcome; chat-message
rows remain the immutable transcript evidence.

## Detection

The send path creates the turn before invoking the model and records durable
activity whenever it persists a turn-owned message. A bounded maintenance sweep
claims stale `pending` or `streaming` rows with a compare-and-swap update. It
does not classify a turn as stalled while it has an unresolved tool
confirmation, a rate-limit pause, or a known terminal failure. The threshold
is a documented constant so it can be made tenant-configurable without changing
the state contract.

Claiming a stalled turn writes one durable system notice. The notice links to
the originating message and any pending confirmations, says that partial tool
activity is preserved, and never claims an answer was produced.

## Recovery and audit

The first release deliberately does not replay a stalled model call. A resume
request is an auditable, deduplicated user action that leaves a side-effecting
tool unexecuted until its existing confirmation is approved. Infrastructure
auto-retry is deferred until a tool supplies an idempotency/checkpoint contract.
Turn metadata records classifications, detection time, recovery requests, and
whether completed tool results existed so those outcomes are queryable without
interpreting free-form transcript text.
