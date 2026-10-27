# Durable Chat Turn Recovery Specs

- [x] **CHAT-TURN-RECOVERY-001** - When a streaming chat turn has no durable
  activity for the configured threshold, the system SHALL mark it stalled and
  persist an in-transcript notice; it SHALL not mark the turn completed.

- [x] **CHAT-TURN-RECOVERY-002** - When a turn is awaiting a tool confirmation
  or the session is rate-limited, the stall sweep SHALL leave it non-stalled.

- [x] **CHAT-TURN-RECOVERY-003** - A stalled turn SHALL retain its partial
  transcript evidence and require an explicit, deduplicated recovery request;
  automatic replay is disabled unless a future checkpoint contract opts in.
