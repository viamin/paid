---
parent: PAID
prefix: CHAT-TURN
---

# Low-Level Design: Durable Chat Turn Recovery

## Purpose

Chat messages are durable evidence, but cannot by themselves state whether a
user turn is still executing, finished, or silently lost. A `ChatTurn` owns
that operational lifecycle for one persisted user message while preserving the
existing transcript as the source of tool and model evidence.

## Decisions & Alternatives

| Decision | Alternatives considered | Rationale |
| --- | --- | --- |
| Store a turn record per user message | Infer status from message timestamps | A durable lifecycle is queryable, auditable, and cannot mistake partial tool history for success. |
| Classify only inactive pending/streaming turns | Mark every old user message stalled | Pending confirmations, rate limits, and declared long operations are intentional pauses. |
| Replay only a tool-free checkpoint once | Replay the whole turn or arbitrary tools | A tool-free user checkpoint can be re-enqueued without duplicating side effects; any tool history requires human review. |

## Lifecycle

`pending` and `streaming` are incomplete states. An assistant conclusion or a
confirmation pause completes the current turn; handled execution errors are
`failed`; detector classification is `stalled`; an operator may later abandon
a turn. The detector runs server-side and, after the configurable timeout,
locks and rechecks a candidate before adding one system notice. The notice
names what remains unknown and preserves the surrounding transcript.

Recovery is revision-aware and locks the turn. It admits at most one recovery
attempt and only re-enqueues the original user checkpoint when no non-system
message follows it. A turn with tool evidence is never blindly replayed; its
notice asks the user to review that evidence. This first slice intentionally
does not enable blanket automatic retry; a future tool must declare an
idempotency/checkpoint contract before broader automatic replay can be added.

## Observability

Classification and recovery emit structured events with the turn/session IDs,
classification, recovery outcome, attempt count, and whether tool activity had
completed. The lifecycle and timestamps are queryable from `chat_turns`.
