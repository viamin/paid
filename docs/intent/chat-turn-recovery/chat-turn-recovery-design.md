---
parent: PAID
prefix: CHAT-TURN-RECOVERY
---

# Low-Level Design: Chat Turn Recovery

Interactive chat records a durable `ChatTurn` for every accepted user message.
The turn is the authority for whether the request is still in progress; browser
stream state is presentation-only.

## Lifecycle

Turns move from `pending` to `streaming`, then to exactly one of `completed`,
`failed`, `stalled`, or `abandoned`. A turn paused on a write-tool confirmation
uses `awaiting_confirmation`; it is deliberately excluded from stall detection.
The turn stores its user-message checkpoint, stream identifier, last durable
activity, classification, and recovery audit data.

## Detection and recovery

The periodic detector locks each due active turn. It ignores pending human
confirmation and records a `stalled` conclusion plus a transcript system
notice when no durable activity arrived within the configured threshold. It
never manufactures an assistant answer or calls a tool while classifying.

Only an infrastructure-interrupted turn with no persisted tool request or
result is eligible for one automatic retry. That condition is the replay
safety contract: `AgentLoop` persists a tool request before dispatch, so an
absence of tool evidence proves no tool dispatch was reached. Other stalled
turns remain visibly stalled and require an explicit, authorized recovery
decision. Row locks and a recovery token prevent concurrent detector workers
from scheduling duplicate recovery.

## Observability

The turn's classification, detection timestamp, recovery count/token, and
terminal timestamps are queryable persisted data. The transcript notice
contains the checkpoint and whether tool activity was observed so users can
see what completed and what remains unknown after a reload.
