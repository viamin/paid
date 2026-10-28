---
parent: PAID
prefix: CHAT-TURN-RECOVERY
---

# Low-Level Design: Chat Turn Recovery

## Purpose

Interactive chat must never silently turn a persisted user message into an
unknown outcome. A `ChatTurn` is the durable lifecycle record for one user
message. It preserves the existing message transcript as evidence while making
unfinished work queryable independently of browser streaming state.

## Lifecycle and detection

New turns begin `pending`, become `streaming` when durable activity is
recorded, and finish as `completed`, `failed`, or `waiting_for_confirmation`.
`waiting_for_confirmation` is intentionally not a failure: the existing
confirmation card owns the next action. A periodic detector considers only
`pending` and `streaming` turns whose `last_activity_at` exceeds the configured
`CHAT_TURN_STALL_THRESHOLD_SECONDS` (ten minutes by default). Under a row lock
it transitions the turn to `stalled` once, records `detected_at`, and writes a
system transcript notice.

The detector deliberately makes no inference from a client disconnect. It
uses durable activity only, so an SSE or ActionCable interruption cannot make a
healthy turn successful or suppress the eventual stalled conclusion. Known
terminal provider, token, and validation failures are recorded as `failed` by
the send service rather than waiting for the detector.

## Recovery safety

The first release does not replay stalled turns automatically. The notice
identifies whether a completed tool result exists after the user message and
offers an explicit safe-retry action. That action records the user's recovery
decision, transitions the old turn to `abandoned`, and directs the user to
start a new turn from the retained transcript.
This is an intentional safe baseline: without a per-tool idempotency contract
and a durable provider checkpoint, replay could repeat a side effect. Future
automatic recovery may be enabled only for an explicit infrastructure failure
classification with an idempotent checkpoint/replay contract; ambiguous model
stops and turns with completed side-effecting tools continue to require an
explicit user decision.

## Auditability

`ChatTurn` stores lifecycle state, last durable activity, stall detection time,
failure classification, recovery count, and metadata. The transition emits a
structured `chat_turn.stalled` event including whether a completed tool result
exists. These columns make stall and abandonment/recovery reporting queryable
without parsing transcript text.

## Decisions & Alternatives

| Decision | Alternatives considered | Rationale |
| --- | --- | --- |
| Persist a dedicated turn row | Infer from messages at read time | A lifecycle query needs a durable, lockable outcome and detector cursor. |
| No automatic replay in the first slice | Retry every stalled request | Existing tools do not yet expose a common idempotency/checkpoint contract. |
