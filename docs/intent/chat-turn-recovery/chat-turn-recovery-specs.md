# EARS Specs: Chat Turn Recovery

- [x] **CHAT-TURN-RECOVERY-001** — When a chat request persists its user
  message, the system SHALL create a durable turn with a server-side activity
  heartbeat and SHALL record completed or failed terminal state.
  *Code:* `ChatSessions::SendMessage`, `ChatTurn`.
  *Test:* `spec/services/chat_sessions/send_message_spec.rb`.

- [x] **CHAT-TURN-RECOVERY-002** — When an unfinished turn has no durable
  activity beyond the configured threshold, the system SHALL atomically mark it
  `stalled` and audit the classification, unless it is waiting for a tool
  confirmation or an active known rate-limit pause.
  *Code:* `ChatTurns::DetectStalled`, `ChatTurns::DetectStalledSweepJob`.
  *Test:* `spec/services/chat_turns/detect_stalled_spec.rb`.

- [x] **CHAT-TURN-RECOVERY-003** — When a turn is classified as stalled, the
  transcript SHALL retain partial evidence and render a durable notice that
  says the remaining response is unknown and whether side-effecting tool
  completion was recorded.
  *Code:* `ChatMessage#stalled_turn_notice?`,
  `chat_messages/_stalled_turn_notice.html.erb`.
  *Test:* `spec/services/chat_turns/detect_stalled_spec.rb`,
  `spec/models/chat_message_spec.rb`.
