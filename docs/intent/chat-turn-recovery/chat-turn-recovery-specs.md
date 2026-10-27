# Chat Turn Recovery Specs

- [x] **CHAT-TURN-RECOVERY-001** - When an Action Cable chat submission starts,
  the system SHALL persist a turn lifecycle record and shall record durable
  message activity and terminal completion or failure.

- [x] **CHAT-TURN-RECOVERY-002** - When a pending or streaming turn has no
  durable activity past the configured threshold, the system SHALL mark it
  stalled under a row lock, unless it is rate-limited or awaiting a tool
  confirmation.

- [x] **CHAT-TURN-RECOVERY-003** - When a turn is marked stalled, the system
  SHALL preserve its transcript and add a durable in-transcript notice that
  explains the unknown outcome and that tools will not be automatically replayed.
