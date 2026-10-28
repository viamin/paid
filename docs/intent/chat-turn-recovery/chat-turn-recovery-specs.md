# Chat Turn Recovery Specs

- [x] **CHAT-TURN-RECOVERY-001** — When a chat turn begins durable execution, the system SHALL persist a lifecycle record with a stream identifier and durable activity timestamp; a turn with no terminal outcome and no durable activity beyond the configured threshold SHALL be classified `stalled`, never `completed`.
  *Tests:* `spec/models/chat_turn_spec.rb`, `spec/jobs/chat_sessions/detect_stalled_turns_job_spec.rb`.
  *Code:* `ChatSessions::SendMessage#start_turn!`, `ChatTurn#stall!`, `ChatSessions::DetectStalledTurnsJob#perform`.

- [x] **CHAT-TURN-RECOVERY-002** — When a turn is awaiting an explicit write-tool confirmation, the inactivity detector SHALL not classify it as stalled.
  *Tests:* `spec/models/chat_turn_spec.rb`, `spec/jobs/chat_sessions/detect_stalled_turns_job_spec.rb`.
  *Code:* `ChatTurn#stallable?`, `ChatTurn.stale_active`.

- [x] **CHAT-TURN-RECOVERY-003** — When a turn is classified stalled, the system SHALL preserve partial transcript evidence and persist one actionable in-transcript notice that states completed tool activity is preserved and automatic replay is unsafe.
  *Tests:* `spec/jobs/chat_sessions/detect_stalled_turns_job_spec.rb`.
  *Code:* `ChatSessions::StallTurn#call`, `ChatMessage#stalled_turn_notice?`.

- [D] **CHAT-TURN-RECOVERY-004** — A future recovery slice SHALL automatically retry only classified infrastructure failures whose checkpointed tools explicitly declare replay-safe idempotency; ambiguous/model stops and any turn with completed side-effecting tools SHALL require explicit confirmation.
