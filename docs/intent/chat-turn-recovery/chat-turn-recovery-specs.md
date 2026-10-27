# EARS Specs: Chat Turn Recovery

- [x] **CHAT-TURN-RECOVERY-001** — When a streaming chat turn has no durable
  activity beyond the configurable timeout, Paid SHALL atomically mark it
  `stalled`; it SHALL NOT mark the turn successful.
  *Tests:* `spec/models/chat_turn_spec.rb`, `spec/services/chat_sessions/detect_stalled_turns_spec.rb`.
  *Code:* `ChatTurn`, `ChatSessions::DetectStalledTurns`.

- [x] **CHAT-TURN-RECOVERY-002** — While a chat turn awaits a user tool
  confirmation or has a declared long-running deadline, Paid SHALL NOT
  classify it as stalled before that condition clears.
  *Tests:* `spec/services/chat_sessions/detect_stalled_turns_spec.rb`.
  *Code:* `ChatTurn#long_running?`, `ChatSessions::DetectStalledTurns`.

- [x] **CHAT-TURN-RECOVERY-003** — When Paid detects a stalled turn, it SHALL
  preserve the transcript and render a durable notice that identifies the
  unknown outcome and offers explicit recovery.
  *Tests:* `spec/services/chat_sessions/detect_stalled_turns_spec.rb`.
  *Code:* `ChatMessage#stalled_turn_notice?`, stalled-turn partial.

- [x] **CHAT-TURN-RECOVERY-004** — When a user resumes a stalled turn, Paid
  SHALL continue from its original durable user-message checkpoint and SHALL
  not replay persisted tool results.
  *Tests:* `spec/services/chat_sessions/resume_stalled_turn_spec.rb`.
  *Code:* `ChatSessions::ResumeStalledTurn`, `ChatSessions::SendMessage`.

- [x] **CHAT-TURN-RECOVERY-005** — When recovery could cause further model or
  tool work, Paid SHALL require an explicit authorized user action.
  *Tests:* `spec/services/chat_sessions/resume_stalled_turn_spec.rb`.
  *Code:* `ChatTurnsController#resume`.

- [x] **CHAT-TURN-RECOVERY-006** — When recovery is requested concurrently or
  repeatedly, Paid SHALL claim it once and SHALL not enqueue duplicate work.
  *Tests:* `spec/services/chat_sessions/resume_stalled_turn_spec.rb`.
  *Code:* `ChatSessions::ResumeStalledTurn`.

- [x] **CHAT-TURN-RECOVERY-007** — Paid SHALL retain queryable stall status,
  classification, timestamps, recovery attempts, and recovery actor metadata.
  *Tests:* `spec/services/chat_sessions/detect_stalled_turns_spec.rb`.
  *Code:* `ChatTurn`.
