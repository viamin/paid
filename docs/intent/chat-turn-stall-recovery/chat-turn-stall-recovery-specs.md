# EARS Specs: Chat turn stall recovery

- [x] **CHAT-TURN-STALL-001** — When an incomplete turn has no durable activity
  beyond the configured threshold, the system SHALL mark it `stalled` and
  preserve the transcript without marking it successful.
- [x] **CHAT-TURN-STALL-002** — When a turn is awaiting confirmation, rate-limit
  recovery, or an explicitly marked long-running operation, detection SHALL NOT
  mark it stalled.
- [x] **CHAT-TURN-STALL-003** — When a turn is marked stalled, the transcript
  SHALL contain a durable warning that identifies preserved partial activity
  and requires review before retrying.
