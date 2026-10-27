# EARS Specs: Durable Chat Turn Recovery

- [x] **CHAT-TURN-RECOVERY-001** — When a chat user message is accepted for
  processing, Paid SHALL persist a turn with a durable non-terminal lifecycle,
  associate its produced messages with that turn, and mark it completed only
  after a final assistant response is persisted; a pending write confirmation
  SHALL remain non-terminal.
  *Tests:* `spec/models/chat_turn_spec.rb`,
  `spec/services/chat_sessions/send_message_spec.rb`.
  *Code:* `ChatTurn`, `ChatSessions::SendMessage`, `ChatSessions::AgentLoop`.

- [x] **CHAT-TURN-RECOVERY-002** — When a streaming chat turn has no durable
  activity past the configured stall threshold, and it is neither waiting for
  confirmation nor parked for a known provider rate limit, Paid SHALL atomically
  mark it stalled and persist exactly one transcript notice that preserves the
  partial state and states that no completion is known.
  *Tests:* `spec/jobs/chat_sessions/detect_stalled_turns_job_spec.rb`,
  `spec/models/chat_message_spec.rb`.
  *Code:* `ChatSessions::DetectStalledTurnsJob`, `ChatTurn`,
  `app/views/chat_messages/_stalled_turn_notice.html.erb`.

- [x] **CHAT-TURN-RECOVERY-003** — When a chat turn is stalled, Paid SHALL not
  automatically replay its model or tool calls; any future automatic recovery
  SHALL require a classified infrastructure failure and an explicit idempotency
  or checkpoint contract, while ambiguous stops and possible side effects require
  an authorized human action.
  *Tests:* `spec/jobs/chat_sessions/detect_stalled_turns_job_spec.rb`.
  *Code:* `ChatSessions::DetectStalledTurnsJob`.
