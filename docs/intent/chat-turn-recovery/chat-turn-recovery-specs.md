# Chat Turn Recovery Specs

- [x] **CHAT-TURN-RECOVERY-001** - When a chat turn has durable partial activity but no terminal outcome beyond the configured threshold, the system SHALL atomically mark it `stalled` and SHALL NOT mark it successful.

- [x] **CHAT-TURN-RECOVERY-002** - When a turn is waiting for a tool confirmation, rate-limit recovery, or has a terminal outcome, the stall detector SHALL NOT classify it as stalled.

- [x] **CHAT-TURN-RECOVERY-003** - When a turn is classified as stalled, the system SHALL preserve the transcript and persist an in-transcript notice explaining that completion is unknown and recovery requires explicit action.

- [x] **CHAT-TURN-RECOVERY-004** - The initial recovery release SHALL NOT automatically replay stalled turns, including turns with completed or proposed tool activity, until an idempotency checkpoint contract is available.
