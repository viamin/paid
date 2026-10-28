# EARS Specs: Chat Turn Recovery

- [x] **CHAT-TURN-RECOVERY-001** — When a chat submission is accepted, the system SHALL persist a `ChatTurn` before model execution and SHALL mark it completed only when a terminal assistant message is durably persisted.

- [x] **CHAT-TURN-RECOVERY-002** — When an unfinished chat turn has no durable activity for the configured stall threshold, the server-side sweep SHALL atomically classify it `stalled`, preserving its messages and recording the classification and detection time.

- [x] **CHAT-TURN-RECOVERY-003** — When a chat turn awaits tool confirmation, is rate-limited, or has a recorded terminal failure, the stall sweep SHALL NOT classify it stalled.

- [x] **CHAT-TURN-RECOVERY-004** — When a turn is classified stalled, the transcript SHALL include one durable actionable system notice explaining that partial work is preserved and that unknown work has not been represented as successful.

- [D] **CHAT-TURN-RECOVERY-005** — When a user requests recovery for a stalled turn, the system SHALL record and deduplicate that request and SHALL NOT automatically replay any tool call; a pending side-effecting tool SHALL remain subject to its existing confirmation guard.
