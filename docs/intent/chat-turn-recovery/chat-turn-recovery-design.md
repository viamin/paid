---
parent: PAID
prefix: CHAT-TURN-RECOVERY
---

# Chat Turn Recovery Design

## Purpose

An interactive chat request is a durable turn, not a browser streaming state.
The server records the turn before dispatching work and records its checkpoint,
terminal outcome, and recovery history. This makes a worker loss observable
without inventing an assistant answer or replaying a tool call.

## Lifecycle

`ChatTurn` belongs to a chat session and progresses from `pending` to
`streaming`, then to `completed`, `failed`, `stalled`, or `abandoned`.
`last_activity_at` advances whenever the user checkpoint or a persisted tool/
assistant message advances the turn. A completion caused by a pending tool
confirmation is terminal for the current turn: the confirmation resolution is
its own later operation.

The five-minute sweep selects only pending or streaming turns with no durable
activity for `CHAT_TURN_STALL_THRESHOLD` (fifteen minutes by default). It does
not classify a rate-limited, budget-limited, failed, completed, or abandoned
turn as stalled. The atomic state update means concurrent sweeps create one
classification and one notice.

## Transcript and recovery boundary

Stalling persists a system notice in the transcript. The notice identifies the
last durable activity and links to any pending confirmation; it says explicitly
that no completion was received. It is evidence, not a fabricated response.

This first slice deliberately provides no automatic replay. A later recovery
slice may resume only from a recorded checkpoint after an infrastructure
failure is classified retryable and every prior tool call declares an
idempotency/checkpoint contract. Model stops and turns with side-effecting
tool evidence require an explicit confirmation and may never replay the whole
turn. Recovery attempts must use a database claim keyed to the turn and its
revision.

## Observability

The turn row records classification, detection time, terminal outcome, and
checkpoint messages. Its indexed state and timestamps make stall and abandoned
turn rates queryable without parsing logs. State transitions also emit
structured logs with turn and session IDs. The future recovery claim will add
attempt, outcome, and duplicate-prevention records before enabling replay.

## Decisions & Alternatives

| Decision | Rationale | Alternative |
| --- | --- | --- |
| Persist a `ChatTurn` row instead of deriving turns from messages | A job can die between persisted messages, and durable state needs an indexed owner. | Infer a turn at render time from message order; rejected because it cannot distinguish a pending worker from a silent stop. |
| Stall only inactive non-terminal work | Pending confirmation and known terminal pauses already have user-visible states. | A universal timeout; rejected because it falsely reports expected waits as failures. |
| Start with observation and notice, not replay | Existing tools do not yet publish an idempotent replay contract. | Re-enqueue every stalled job; rejected because it can duplicate side effects. |
