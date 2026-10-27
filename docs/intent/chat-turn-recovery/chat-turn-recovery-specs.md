# EARS Specs: Chat Turn Recovery

- [x] **CHAT-TURN-001** — When a pending or streaming chat turn has no durable activity beyond the configured threshold, Paid SHALL mark it stalled, never completed, and persist an in-transcript notice explaining that the final outcome is unknown while preserving prior messages and tool evidence.
  *Tests:* `spec/services/chat_turns/detect_stalled_spec.rb`.
  *Code:* `ChatTurns::DetectStalled`, `ChatTurn`.

- [x] **CHAT-TURN-002** — When a turn awaits a user tool confirmation or an active provider rate-limit recovery window, Paid SHALL not classify it as stalled.
  *Tests:* `spec/services/chat_turns/detect_stalled_spec.rb`.
  *Code:* `ChatTurns::DetectStalled`.
