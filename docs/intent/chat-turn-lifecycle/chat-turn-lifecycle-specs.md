# EARS Specs: Chat Turn Lifecycle

- [x] **CHAT-TURN-LIFECYCLE-001** — When a persisted chat turn remains `pending` or `streaming` with no durable activity for the configured stall threshold, and it has no pending tool confirmation, the system SHALL atomically mark it `stalled`, record the detection classification and time, and persist an in-transcript system notice that no terminal completion was recorded.
- [x] **CHAT-TURN-LIFECYCLE-002** — When a chat turn has a pending write-tool confirmation, a known provider pause, budget exhaustion, or another recorded terminal outcome, the stall detector SHALL NOT classify it as stalled.
- [x] **CHAT-TURN-LIFECYCLE-003** — The first lifecycle slice SHALL preserve partial transcript evidence and SHALL NOT automatically replay a stalled turn or fabricate an assistant completion; automatic recovery requires a tool-level idempotency and checkpoint contract.
