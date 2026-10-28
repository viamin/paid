---
parent: PAID
prefix: CHAT-TURN-RECOVERY
---

# Low-Level Design: Chat Turn Recovery

## Purpose

A chat request must have a durable conclusion even when its worker or transport
disappears after persisting the user message or tool evidence. The turn record
is the server-owned lifecycle; browser streaming state is only a projection of
that record.

## Lifecycle and evidence

`ChatTurn` belongs to a session and initiating user message. It records
`pending`, `streaming`, `completed`, `failed`, `stalled`, or `abandoned`, the
last durable activity time, terminal classification, revision, and recovery
metadata. Messages produced during the turn link back to it, preserving tool
calls, results, and confirmations as checkpoint evidence.

Persisting a message or receiving a response chunk advances durable activity.
A terminal assistant message completes the turn. A caught provider, budget,
rate-limit, or client-disconnect error fails or pauses it with an explicit
classification. A write-tool confirmation pauses the turn without making it
eligible for stall detection.

## Detection and transcript notice

A scheduled sweep claims non-paused `pending` or `streaming` turns whose last
activity is older than `CHAT_TURN_STALL_THRESHOLD` (15 minutes by default).
The claim is atomic and changes the state to `stalled`; a concurrent terminal
transition therefore wins or observes the new revision rather than silently
overwriting it.

Classification persists whether side-effecting tool results were already
recorded. The sweep adds one durable system notice to the transcript. The
notice states what evidence exists, what remains unknown, and links to the
recorded tool messages. It never fabricates an assistant answer.

## Recovery

The first release treats an unexplained stall as ambiguous and never retries it
automatically. An authorized user may explicitly Resume the exact stalled
revision. The action creates a unique recovery attempt, atomically moves the
turn back to `pending`, and enqueues processing with the original stream key.
Repeated or concurrent requests for that revision return the existing attempt.

Processing reuses the original user message and reconstructed transcript. Tool
results already persisted are model context rather than newly dispatched work;
write tools still use the existing confirmation boundary. Recovery records its
requester, source revision, timestamps, and outcome. A future automatic path
may be added only for a classified infrastructure failure whose checkpoint and
every replayable tool carry an explicit idempotency contract.

## Observability

Turn state, classification, detection time, side-effect evidence, recovery
attempts, outcomes, and deduplication count are queryable columns. Structured
logs are emitted for stall detection, recovery requests, duplicate prevention,
and recovery outcomes with session and turn correlation identifiers.

## Decisions and Alternatives

| Decision | Alternative | Rationale |
| --- | --- | --- |
| Use a turn table | Infer turns from message gaps | Durable lifecycle and concurrency cannot be represented reliably by transcript timing. |
| Require explicit resume for v1 stalls | Automatically replay all stalls | A missing terminal event does not establish whether an external side effect occurred. |
| Reuse the original stream checkpoint | Insert a second user message | Duplicate prompts make tool replay more likely and obscure the original evidence boundary. |
| Keep Temporal optional | Require a chat workflow migration | Detection and safe manual recovery only require durable rows, locking, and the existing job runner. |

## References

- `docs/high-level-design.md` — No silent stops and observable everything
- `docs/intent/chat-tool-confirmation/`
- `docs/intent/notification-severity/`
