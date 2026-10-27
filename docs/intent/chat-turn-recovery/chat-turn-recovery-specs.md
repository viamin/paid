# Chat turn recovery EARS specs

- [x] **CHAT-TURN-001** — When a chat worker starts a turn, the system SHALL persist a durable turn lifecycle record, checkpoint persisted activity, and mark a normal or classified-error outcome terminal.

  *Tests:* `spec/jobs/chat_sessions/process_message_job_spec.rb`.

- [x] **CHAT-TURN-002** — When a streaming chat turn has no durable activity for ten minutes, the system SHALL mark it `stalled` and preserve a non-success transcript notice describing the uncertainty.

  *Tests:* `spec/services/chat_sessions/detect_stalled_turns_spec.rb`.

- [x] **CHAT-TURN-003** — When a chat turn is awaiting an explicit tool confirmation or a known rate-limit recovery window, the system SHALL NOT classify that turn as stalled.

  *Tests:* `spec/services/chat_sessions/detect_stalled_turns_spec.rb`.
