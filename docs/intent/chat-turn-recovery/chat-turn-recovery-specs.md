# Chat Turn Recovery Specs

- [x] **CHAT-TURN-RECOVERY-001** — When an interactive chat request is accepted, the system SHALL persist one durable turn and transition it to a terminal completed or failed state, or a paused confirmation state, without representing a missing outcome as successful.
  *Tests:* `spec/services/chat_sessions/send_message_spec.rb`, `spec/jobs/chat_sessions/process_message_job_spec.rb`.
  *Code:* `ChatSessions::SendMessage#call`, `ChatSessions::ProcessMessageJob#perform`, `ChatTurn`.

- [x] **CHAT-TURN-RECOVERY-002** — When a pending or streaming turn has no durable activity beyond the configured threshold, the detector SHALL atomically mark it stalled and persist an in-transcript notice; turns with a pending tool confirmation or a rate-limit pause SHALL not be stalled.
  *Tests:* `spec/jobs/chat_sessions/detect_stalled_turns_job_spec.rb`.
  *Code:* `ChatSessions::DetectStalledTurnsJob#perform`, `ChatSessions::StallTurn#call`.

- [x] **CHAT-TURN-RECOVERY-003** — When a user requests recovery of a stalled turn, the system SHALL deduplicate concurrent requests and SHALL not replay a turn after a completed write tool; it SHALL retain the transcript and record the recovery outcome.
  *Tests:* `spec/services/chat_sessions/recover_stalled_turn_spec.rb`.
  *Code:* `ChatSessions::RecoverStalledTurn#call`, `ChatTurn`.
