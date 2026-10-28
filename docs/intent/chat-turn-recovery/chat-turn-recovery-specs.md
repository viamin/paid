# EARS Specs: Chat Turn Recovery

- [x] **CHAT-TURN-RECOVERY-001** — When Paid persists a user message for an
  interactive chat turn, it SHALL create or reuse one durable turn record and
  record lifecycle progress and durable activity independently of browser
  streaming state.
  *Tests:* `spec/services/chat_sessions/send_message_spec.rb`.
  *Code:* `ChatSessions::SendMessage`, `ChatTurn`.

- [x] **CHAT-TURN-RECOVERY-002** — When an active chat turn has no durable
  activity for `ChatTurn::STALL_THRESHOLD`, Paid SHALL atomically mark it
  `stalled`, record detection time and classification, and preserve its
  transcript. Turns awaiting human tool confirmation or a known rate-limit
  pause SHALL not be marked stalled.
  *Tests:* `spec/jobs/chat_sessions/stall_detector_job_spec.rb`.
  *Code:* `ChatSessions::StallDetectorJob`, `ChatTurn`.

- [x] **CHAT-TURN-RECOVERY-003** — When a turn is classified as stalled, Paid
  SHALL append one visible system notice identifying the last durable activity,
  unknown remaining work, and any pending confirmation. It SHALL not represent
  the turn as successful or automatically replay a tool call.
  *Tests:* `spec/jobs/chat_sessions/stall_detector_job_spec.rb`,
  `spec/models/chat_message_spec.rb`.
  *Code:* `ChatSessions::StallDetectorJob`, `ChatMessage`.
