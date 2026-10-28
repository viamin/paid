---
parent: paid
prefix: CHAT-TURN-STALL
---

# Chat turn stall recovery

Chat turns are durable records separate from transcript messages. A turn is
incomplete while `pending` or `streaming`, and becomes terminal only when the
assistant completes, a tool confirmation pauses it, or an error is recorded.
The maintenance detector classifies only stale turns with no durable activity.
It excludes rate-limit pauses, pending confirmations, and explicitly marked
long-running operations. A stall preserves all transcript evidence and adds a
system notice; it never creates a successful assistant response.

Automatic replay is intentionally deferred until a tool checkpoint and
idempotency contract exist. Any future resume/retry must inspect the stalled
turn under a lock, require authorization and an unchanged revision, and refuse
to replay completed side-effecting work.
