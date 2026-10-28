---
parent: PAID
prefix: CHAT-TURN-RECOVERY
---

# Low-Level Design: Chat Turn Recovery

## Purpose

Chat turns are durable work, not browser streaming state. A missing terminal
assistant response is recorded as `stalled`, never inferred to be successful.
The transcript retains every persisted message and tool result so an operator
can determine what completed before choosing the next action.

## Lifecycle

`ChatTurn` records `pending`, `streaming`, `pending_confirmation`,
`completed`, `failed`, `stalled`, and `abandoned`. Processing records durable
activity whenever it persists a message. Known terminal failures are `failed`;
a write-tool pause is `pending_confirmation`; rate-limit pauses remain outside
stall detection. The detector marks an active turn stalled only after the
configurable inactivity threshold and writes one in-transcript system notice
in the same row lock.

## Recovery safety

The first slice does not replay a turn automatically. This preserves the
existing tool-confirmation boundary: a stalled transcript is evidence, not
authorization to repeat a side effect. A later resume implementation must use
a durable checkpoint, a revision/authorization check, and an idempotency
contract before infrastructure-class retries are enabled.

## Observability

The turn row stores lifecycle state, classification, activity and detection
times, recovery count, and metadata. Detection emits structured logging with
the turn and session identifiers plus whether a tool result exists.
