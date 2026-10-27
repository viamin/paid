# Chat Turn Recovery Specs

- [x] **CHAT-TURN-RECOVERY-001** — When a persisted chat turn remains pending
  or streaming without durable activity beyond the configured threshold, the
  system SHALL mark it `stalled`, never `completed`, and retain its transcript.
- [x] **CHAT-TURN-RECOVERY-002** — The detector SHALL not stall a turn while
  its session is rate-limited or it has a pending tool confirmation.
- [x] **CHAT-TURN-RECOVERY-003** — Stalling a turn SHALL append one durable,
  actionable transcript notice describing completed evidence and uncertainty;
  repeated detection SHALL not duplicate that notice.
