# Chat Turn Recovery Specs

- [x] **CHAT-TURN-RECOVERY-001** — When a chat message is accepted, the system SHALL persist a turn keyed by its session and stream id and record each durable activity checkpoint.

- [x] **CHAT-TURN-RECOVERY-002** — When a pending or streaming turn has no durable activity beyond the configured threshold, the system SHALL atomically classify it as `stalled`, retain its transcript, record an audit event, and persist an actionable transcript notice; it SHALL never classify the turn as completed.

- [x] **CHAT-TURN-RECOVERY-003** — The stalled-turn detector SHALL not classify a turn while its session is rate-limited, a write-tool confirmation is pending, or its explicit long-operation checkpoint has not expired.

- [x] **CHAT-TURN-RECOVERY-004** — Automatic replay SHALL remain disabled for ambiguous stalled turns; recovery evidence and duplicate-prevention are retained for a later explicit, authorization-aware resume action.
