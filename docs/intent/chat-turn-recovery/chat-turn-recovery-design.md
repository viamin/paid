---
parent: PAID
prefix: CHAT-TURN-RECOVERY
---

# Low-Level Design: Chat Turn Recovery

## Purpose

Interactive chat must never leave a persisted user request and partial tool
evidence without a durable conclusion. A `ChatTurn` is the lifecycle record
for one dispatched user turn; transcript rows remain the content authority.

## Lifecycle

`ChatTurn` begins `pending`, changes to `streaming` before its user message is
persisted, and records its most recent durable activity. It becomes
`completed` after a final assistant response, `awaiting_confirmation` after a
write-tool confirmation pause, or `failed` when an execution error reaches the
turn boundary. `stalled` is reserved for a server-side timeout classification;
it is never a successful terminal state. `abandoned` is reserved for a later
explicit user decision.

The detector only considers `pending` and `streaming` rows whose durable
activity timestamp is older than `CHAT_TURN_STALL_TIMEOUT_SECONDS` (ten
minutes by default). Confirmation pauses are a distinct state and cannot be
misclassified. Known rate-limit and provider outcomes fail at their existing
boundary and are therefore likewise excluded from the inactivity query.

## Detection and transcript evidence

The maintenance job runs every five minutes with a singleton concurrency key.
Its conditional status update claims the stall exactly once, preventing
concurrent sweeps from generating duplicate notices. It persists an
in-transcript system notice linked to the turn, preserving the existing user,
tool-call, and tool-result rows. The notice explains that completed tool
activity is preserved, remaining work is unknown, and a new request requires
review rather than an unsafe replay.

Structured logs include the turn/session identifiers, classification, and
whether a tool result exists. These durable rows and classifications are
queryable by status, activity time, and session.

## Recovery boundary

This first slice deliberately does not automatically replay stalled work.
Existing tool completion records are retained, but no generic tool idempotency
contract exists that would make replay safe. A later recovery slice must add a
revision- and authorization-aware checkpoint plus a unique recovery claim;
automatic retry may then be enabled only for an explicitly classified
infrastructure failure and tools that declare an idempotency/replay contract.
Ambiguous stops and turns with completed side-effecting tools remain explicit
user-review work.

## Decisions and alternatives

| Decision | Rationale | Alternative rejected |
| --- | --- | --- |
| Separate `ChatTurn` from transcript messages | Lifecycle queries and atomic terminal conclusions cannot safely be inferred from browser streaming or message ordering. | Add lifecycle flags to `ChatMessage`; one turn has many rows and partial tool evidence. |
| No automatic replay in the first slice | No per-tool checkpoint/idempotency declaration exists yet. | Re-run the original prompt; this could duplicate side effects. |
