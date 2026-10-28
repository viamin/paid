---
parent: PAID
prefix: CHAT-TURN-RECOVERY
---

# Low-Level Design: Chat Turn Recovery

## Purpose

Interactive chat must not silently stop after accepting a user message. A turn
therefore has a durable lifecycle independent of the browser stream, preserving
the transcript and its tool evidence until it reaches a terminal outcome or is
explicitly recovered.

## Lifecycle and detection

Each user message anchors one `ChatTurn`. Its state is `pending`, `streaming`,
`completed`, `failed`, `stalled`, or `abandoned`; persisted messages advance
`last_activity_at`. The scheduled detector examines only open turns that have
been quiet past the configurable tenant threshold (with a platform floor).

The classifier keeps pending confirmations and declared long-running tools
open, records budget/provider terminal failures as failed, marks a browser
disconnect as abandoned, and marks unexplained silence as stalled. A stalled
turn is never represented as a completed assistant response.

## Recovery safety

Recovery resumes from the original user-message checkpoint. A durable replay
guard returns a previously recorded tool result and refuses a matching completed
write tool, so a resumed turn cannot blindly repeat a side effect. Automatic
recovery is limited to opted-in infrastructure failures with no completed write
tool and a bounded attempt count. All ambiguous stops and any turn with side
effects require a user action.

Recovery requests use the turn row as a compare-and-swap claim and include the
notice revision; stale views and concurrent requests cannot start duplicate
recoveries. Events record classification, recovery request/start/outcome, user
actor, and prevented duplicates for queryable audit evidence.

## Presentation

The detector persists one in-transcript notice for a stalled or abandoned turn.
It identifies recorded tool activity, what remains unknown, the classification,
and a Resume action. The action uses ordinary chat authorization and the
revision rendered in the notice.

## Decisions and alternatives

| Decision | Alternatives considered | Rationale |
| --- | --- | --- |
| Persist a turn beside messages | Infer from transient ActionCable state | Durable state survives disconnected clients and process failures. |
| Resume with a replay guard | Replay the original prompt and tools | Recorded checkpoints preserve evidence and prevent repeated completed writes. |
| Cron detector with bounded automatic recovery | Require Temporal orchestration first | This first slice remains small while making silent stops visible and safe. |

## Observability

`ChatTurnEvent` is append-only. Its classifications, recovery outcomes, user
actions, side-effect flag, and duplicate-prevention rows provide stall-rate,
recovery-success, abandonment, and duplicate-prevention queries.
