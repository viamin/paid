---
parent: PAID
prefix: CHAT-TURN-RECOVERY
---

# Low-Level Design: Chat Turn Recovery

## Purpose

An interactive chat request is durable work, not browser streaming state. A
persisted user message must therefore have a durable turn outcome even when a
worker dies after recording partial tool evidence. This segment adds a small
server-side lifecycle and a conservative stalled-turn detector.

## Lifecycle and evidence

Each submitted message creates one `ChatTurn`, keyed by session and transport
stream id. A turn moves from `pending` to `streaming`, then to `completed`,
`failed`, `stalled`, or `abandoned`. `ChatTurnEvent` is append-only audit
evidence for starts, durable activity, classifications, and future recovery
attempts. A stalled turn is never represented as completed.

The detector only considers pending/streaming turns past the configurable
`CHAT_TURN_STALL_TIMEOUT` (default 15 minutes). It excludes turns awaiting a
write-tool confirmation, sessions paused for a known provider rate limit, and
turns with an explicit `stall_exempt_until` checkpoint for a known long-running
operation. Classification and notice creation happen while the turn row is
locked, making repeated sweeps idempotent.

## Transcript and recovery boundary

Detection preserves all existing messages and writes a visible system notice
describing the last durable activity and any completed tools. The first slice
does not replay a turn automatically: an unknown model stop is ambiguous, and
replaying it could issue another side-effecting tool call. Existing rate-limit
recovery remains separately classified infrastructure recovery. A later
resume action must claim the same turn under lock, check revision and actor
authorization, and only resume from its persisted checkpoint after explicit
confirmation when tool effects are ambiguous.

## Decisions & Alternatives

| Decision | Alternatives considered | Rationale |
| --- | --- | --- |
| Persist turn rows rather than infer turns from messages | Browser state; message timestamp heuristics | A row gives an atomic lifecycle, audit key, and concurrency boundary without changing the transcript. |
| Start with detection and notice, not generic replay | Retry every stopped request | Partial tool activity is evidence, not proof that rerunning is safe. |
