# EARS Specs: Chat Turn Recovery

- [x] **CHAT-TURN-RECOVERY-001** — When a chat turn persists a user message,
  Paid SHALL create a durable turn lifecycle record and SHALL mark it completed
  only after a persisted response or a durable confirmation pause.
  *Tests:* `spec/services/chat_sessions/send_message_spec.rb`.
  *Code:* `ChatSessions::SendMessage`, `ChatTurns::Start`, `ChatTurns::Complete`.

- [x] **CHAT-TURN-RECOVERY-002** — When an active turn has no durable activity
  beyond the configured threshold, Paid SHALL atomically mark it stalled and
  SHALL preserve its transcript; turns awaiting confirmation or holding a
  declared long-operation lease SHALL not be marked stalled.
  *Tests:* `spec/services/chat_turns/detect_stalls_spec.rb`.
  *Code:* `ChatTurns::DetectStalls`, `ChatTurn`.

- [x] **CHAT-TURN-RECOVERY-003** — When a turn becomes stalled, Paid SHALL
  persist an in-transcript notice explaining that the remaining response is
  unknown and warning against replaying side-effecting work without explicit
  confirmation.
  *Tests:* `spec/services/chat_turns/detect_stalls_spec.rb`,
  `spec/views/chat_messages/message_partial_spec.rb`.
  *Code:* `ChatTurns::DetectStalls`, `ChatMessage`,
  `chat_messages/_stalled_turn_notice`.

- [D] **CHAT-TURN-RECOVERY-004** — Automatic recovery SHALL run only for a
  classified infrastructure failure with an idempotent replay contract; all
  ambiguous or side-effecting recovery SHALL require explicit confirmation.
  This is deferred until tools expose durable checkpoint/idempotency contracts.
