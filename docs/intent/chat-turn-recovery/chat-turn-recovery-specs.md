# Chat Turn Recovery EARS Specs

- [x] **CHAT-TURN-RECOVERY-001**: When a chat send begins, the system shall persist a turn with its initiating message, actor, stream identity when available, and durable activity timestamp before model work begins.
- [x] **CHAT-TURN-RECOVERY-002**: When a chat turn produces a normal response or pauses for explicit tool confirmation, the system shall mark the turn completed without replaying pending tools.
- [x] **CHAT-TURN-RECOVERY-003**: When a non-terminal chat turn has no durable activity for the configured threshold, the system shall atomically mark it stalled and preserve an in-transcript notice stating that completion is unknown.
- [x] **CHAT-TURN-RECOVERY-004**: While a turn is waiting for confirmation, rate-limited, or terminal, the stall detector shall not classify it as stalled.
- [x] **CHAT-TURN-RECOVERY-005**: When a detector encounters the same stalled turn repeatedly or concurrently, the system shall create no duplicate stall notice.
