---
parent: PAID
prefix: CHAT-TURN-RECOVERY
---

# Low-Level Design: Durable Chat Turn Recovery

> Companion to the high-level design (`docs/high-level-design.md`).

## Purpose

An interrupted chat request must not leave a user message and partial tool
history that looks like a successful answer. This segment records each
user-initiated turn independently of its transport stream, preserves the
partial transcript, and makes an overdue non-terminal turn visible.

## Lifecycle

`ChatTurn` belongs to a chat session and starts when `SendMessage` persists the
user message. Its state is `pending`, `streaming`, `completed`, `failed`,
`stalled`, or `abandoned`. Every persisted assistant or tool message belonging
to the turn advances its durable activity timestamp. A final assistant message
completes the turn; a pending tool confirmation remains `pending` rather than
being classified as a failure.

The maintenance sweep considers only `streaming` turns whose last durable
activity is older than the configured threshold. It excludes turns with a
pending confirmation and sessions parked for a known provider rate limit.
The sweep atomically transitions a candidate to `stalled`, records the
classification time, and appends one system notice to the transcript. The
notice names the preserved partial state and directs the user to an explicit
resume path; it never invents an assistant answer or changes tool results.

## Recovery boundary

The first release detects and explains uncertain stops. It deliberately does
not automatically replay a stalled model call or any tool call. Existing
tool-call/result rows remain the checkpoint for a later opt-in recovery
contract. That contract may permit bounded infrastructure retries only after a
tool declares an idempotency/checkpoint guarantee; ambiguous stops and any
recovery that could repeat a side effect require an authorized human action.

## Observability

Turn state, durable activity, stall classification time, and the notice's
partial-state summary are queryable records. The sweep emits structured counts
and per-turn classification logs; this makes stalled-turn and abandoned-turn
rates derivable without treating a browser disconnect as success.

## Decisions & Alternatives

| Decision | Rationale | Alternative considered |
| --- | --- | --- |
| Persist a `ChatTurn` instead of inferring state from message order | Concurrent streams and partial tool output make transcript-only inference ambiguous. | Add metadata only to user messages; rejected because it cannot safely own lifecycle transitions. |
| Start with no automatic replay | A timeout cannot prove a side-effecting tool did not complete. | Retry every stalled turn; rejected because it risks duplicate mutations. |
