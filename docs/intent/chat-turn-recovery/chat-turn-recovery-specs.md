# EARS Specs: Chat Turn Recovery

- [x] **CHAT-TURN-RECOVERY-001** — When a pending or streaming chat turn has no durable activity for the configured threshold, Paid SHALL atomically mark it stalled, preserve its transcript, record an auditable classification event, and create an in-transcript notice; it SHALL NOT represent that turn as successful.
  *Tests:* `spec/services/chat_sessions/detect_stalled_turns_spec.rb`.
  *Code:* `ChatSessions::DetectStalledTurns`, `ChatSessions::StalledTurnDetectorJob`.

- [x] **CHAT-TURN-RECOVERY-002** — When a chat turn is awaiting an unresolved tool confirmation, Paid SHALL not classify it as stalled.
  *Tests:* `spec/services/chat_sessions/detect_stalled_turns_spec.rb`.
  *Code:* `ChatSessions::DetectStalledTurns`.

- [x] **CHAT-TURN-RECOVERY-003** — When a chat turn completes, fails, or makes durable progress, Paid SHALL record its lifecycle outcome or activity so detection and operational queries can distinguish it from a silent stop.
  *Tests:* `spec/models/chat_turn_spec.rb`.
  *Code:* `ChatTurn`, `ChatSessions::SendMessage`, `ChatSessions::ProcessMessageJob`.

- [x] **CHAT-TURN-RECOVERY-004** — When an authorized user explicitly retries a stalled chat turn with its current revision, Paid SHALL record the recovery request and enqueue at most one recovery; stale or concurrent requests SHALL not enqueue a duplicate.
  *Tests:* `spec/services/chat_sessions/retry_stalled_turn_spec.rb`.
  *Code:* `ChatSessions::RetryStalledTurn`.
