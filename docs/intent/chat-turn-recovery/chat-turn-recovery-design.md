---
parent: PAID
prefix: CHAT-TURN-RECOVERY
---

# Low-Level Design: Chat Turn Recovery

## Purpose

An interactive chat turn must end durably. A persisted user message plus
partial tool activity is evidence of work, not a successful assistant reply.
This segment records each turn's lifecycle, detects turns whose server-side
activity stopped, and makes the resulting uncertainty visible in the
transcript.

## Lifecycle

`ChatTurn` is the durable owner of one user message. It begins `streaming`;
the service marks it `completed` only after a terminal assistant reply, and
marks it `pending_confirmation` when the loop intentionally pauses on a
write-tool confirmation. Known token-budget, provider, and rate-limit paths
are terminal or explicitly paused states rather than stalls. A periodic sweep
atomically moves only inactive `streaming` turns to `stalled` and records the
detection time and classification.

The sweep uses the turn's last durable activity timestamp, not browser stream
state. The threshold is a named model constant so deployment configuration can
override it without weakening the state contract.

## User-visible evidence

Stalling creates one durable system notice. It states that no completion was
recorded, preserves existing transcript/tool evidence, and tells the user to
review outstanding confirmations or retry deliberately. Notices are never
rendered as assistant output and are excluded from collapsed tool runs.

## Recovery boundary

This first slice detects and explains stalled turns; it deliberately does not
replay them. Existing rate-limit recovery remains its separately classified,
bounded infrastructure path. A later resume action must claim the turn
atomically, bind the actor and current revision/authorization, resume from a
durable checkpoint, and require explicit confirmation whenever a completed or
potentially side-effecting tool could be replayed. Automatic replay additionally
requires an idempotency contract for every participating tool.

## Observability

The turn row retains lifecycle state, durable activity, detection time, and
classification. The detector logs a structured classification event and the
notice carries the turn id, so stall rates, abandoned turns, and future
recovery outcomes can be queried without inferring state from prose.
