---
parent: PAID
prefix: CHAT-TURN-RECOVERY
---

# Low-Level Design: Chat Turn Recovery

## Purpose

Chat turns have a durable lifecycle so a persisted request cannot disappear
behind transient browser streaming state. Paid preserves partial transcript
evidence, classifies inactivity, and presents a safe recovery decision without
claiming that unknown work succeeded.

## Durable lifecycle

Each user request owns one `ChatTurn`, identified by its persisted user message
and stream key. Its lifecycle is `pending`, `streaming`, `completed`, `failed`,
`stalled`, or `abandoned`. Heartbeats and a renewable activity lease distinguish
an inactive turn from known long-running work. `pause_reason` distinguishes a
confirmation pause, rate limit, budget stop, provider failure, and client
disconnect from an unexplained stall.

Every persisted assistant or tool row advances the turn's durable checkpoint.
The turn also records whether a side-effecting tool completed. The transcript
is never deleted during classification or recovery.

## Detection and notice

A periodic, tenant-aware sweep claims inactive pending or streaming turns in
batches. It excludes turns with an unexpired lease and turns waiting for an
explicit tool confirmation. The transition to `stalled` and its detection time
is atomic. Exactly one system notice is persisted for the turn, describing the
last checkpoint, whether side effects completed, and that remaining work is
unknown.

The inactivity threshold is configured through
`CHAT_TURN_STALL_THRESHOLD_SECONDS`, with a conservative application default.

## Recovery authority and replay safety

Recovery locks the turn, checks its revision, reauthorizes the actor against
the current chat session, and creates a uniquely active recovery attempt.
Restarting uses the original stream key, so the existing chat loop rebuilds
from the persisted transcript and tool results instead of inserting another
user request.

Ambiguous stalls and every turn with a completed side-effecting tool require an
explicit user confirmation. Automatic recovery is limited to one attempt for a
classified infrastructure failure with no completed side effect. Concurrent or
repeated requests return the already-active attempt rather than dispatching
duplicate work.

## Observability

Turns expose queryable state, classification, detection time, pause reason,
side-effect completion, recovery count, and recovery outcome. Recovery attempts
record actor, automatic/manual origin, revision, timestamps, outcome, and the
deduplication key. Structured logs accompany stall, recovery, and duplicate
prevention transitions.

## Decisions & Alternatives

| Decision | Rationale | Alternative |
| --- | --- | --- |
| Persist a turn record rather than infer state from message order | Absence of a message cannot explain whether work is active, paused, failed, or unknown. | Continue reconstructing state in the browser. |
| Resume from persisted transcript checkpoints | Existing stream-key reuse and tool-result reconstruction preserve evidence and avoid replaying the whole request. | Delete partial rows and resend the prompt. |
| Keep automatic recovery opt-in and infrastructure-only | Unknown model stops and completed mutations cannot safely be replayed without human authority. | Retry every stale request. |
