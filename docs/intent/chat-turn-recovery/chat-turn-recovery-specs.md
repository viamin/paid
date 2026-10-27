# EARS Specs: Chat Turn Recovery

- [x] **CHAT-TURN-001** — When a persisted chat user message begins processing, the system SHALL create or reuse one durable turn and record lifecycle events; it SHALL mark the turn completed only after a final assistant message is persisted, and SHALL mark a confirmation pause as awaiting confirmation.
  *Tests:* `spec/models/chat_turn_spec.rb`.
  *Code:* `app/services/chat_sessions/send_message.rb`, `app/models/chat_turn.rb`.

- [x] **CHAT-TURN-002** — When an active turn has no durable activity past the configured stall threshold, the system SHALL mark it stalled and record a queryable classification event; turns awaiting explicit confirmation SHALL NOT be stalled.
  *Tests:* `spec/services/chat_turns/detect_stalled_spec.rb`.
  *Code:* `app/services/chat_turns/detect_stalled.rb`, `app/jobs/chat_sessions/detect_stalled_turns_job.rb`.

- [x] **CHAT-TURN-003** — When a turn is classified stalled, the transcript SHALL retain its prior evidence and display a durable notice that later work is unknown and no tool calls were replayed automatically.
  *Tests:* `spec/services/chat_turns/detect_stalled_spec.rb`.
  *Code:* `app/views/chat_messages/_stalled_turn_notice.html.erb`, `app/models/chat_message.rb`.
