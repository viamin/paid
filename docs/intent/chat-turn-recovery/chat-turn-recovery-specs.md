# EARS Specs: Chat Turn Recovery

- [x] **CHAT-TURN-RECOVERY-001** — When Paid persists a user message for an
  interactive chat turn, it SHALL create a durable turn lifecycle record and
  SHALL mark that record completed only after a terminal assistant message is
  persisted; it SHALL never infer success from partial tool activity.
  *Tests:* `spec/models/chat_turn_spec.rb`, `spec/services/chat_sessions/send_message_spec.rb`,
  `spec/services/chat_sessions/resolve_tool_call_turn_lifecycle_spec.rb`.
  *Code:* `ChatTurn`, `ChatSessions::SendMessage`, `ChatSessions::ResolveToolCall`.

- [x] **CHAT-TURN-RECOVERY-002** — When an in-progress chat turn has no durable
  activity for the configured threshold, Paid SHALL atomically classify it as
  stalled, record when it was detected, and persist one visible transcript
  notice explaining that completion is unknown. Turns paused for pending human
  confirmation or a known provider rate limit SHALL NOT be classified stalled.
  *Tests:* `spec/jobs/chat_sessions/detect_stalled_turns_job_spec.rb`.
  *Code:* `ChatSessions::DetectStalledTurnsJob`, `ChatTurn`, `ChatMessage`.

- [x] **CHAT-TURN-RECOVERY-003** — A stalled-turn notice SHALL preserve rather
  than fabricate the assistant result, identify the affected turn, and direct
  the user to deliberate retry/recovery; automatic replay remains disabled
  unless a separately implemented classified infrastructure path proves its
  checkpoint and tool idempotency safety.
  *Tests:* `spec/models/chat_message_spec.rb`.
  *Code:* `ChatTurn#stall!`, `ChatMessage#stalled_turn_notice?`.
