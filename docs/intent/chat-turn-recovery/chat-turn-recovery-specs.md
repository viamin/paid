# EARS Specs: Chat Turn Recovery

- [x] **CHAT-TURN-RECOVERY-001** — When a persisted user chat message has a
  turn in `pending` or `streaming` with no durable activity for longer than
  `CHAT_TURN_STALL_THRESHOLD_SECONDS` (ten minutes by default), the scheduled
  detector SHALL transition it to `stalled` exactly once and record its
  detection time; it SHALL not represent the turn as successful.
  *Code:* `ChatTurn`, `ChatSessions::DetectStalledTurns`,
  `ChatSessions::DetectStalledTurnsJob`.
  *Test:* `spec/models/chat_turn_spec.rb`,
  `spec/services/chat_sessions/detect_stalled_turns_spec.rb`.

- [x] **CHAT-TURN-RECOVERY-002** — When a turn is classified as stalled, the
  system SHALL persist an in-transcript system notice that states the missing
  final response, preserves prior activity as evidence, identifies the affected
  turn, and warns when a completed tool result may have changed state.
  *Code:* `ChatSessions::DetectStalledTurns`, `ChatMessage#stalled_turn_notice?`.
  *Test:* `spec/services/chat_sessions/detect_stalled_turns_spec.rb`.

- [x] **CHAT-TURN-RECOVERY-003** — A turn waiting for an existing explicit
  tool confirmation SHALL remain `waiting_for_confirmation` and SHALL NOT be
  classified as stalled by inactivity detection.
  *Code:* `ChatTurn`, `ChatSessions::SendMessage`.
  *Test:* `spec/services/chat_sessions/detect_stalled_turns_spec.rb`.

- [x] **CHAT-TURN-RECOVERY-004** — Repeated or concurrent detector executions
  SHALL create no more than one stalled outcome or transcript notice for the
  same turn.
  *Code:* `ChatSessions::DetectStalledTurns`.
  *Test:* `spec/services/chat_sessions/detect_stalled_turns_spec.rb`.

- [x] **CHAT-TURN-RECOVERY-005** — When an authorized user selects safe retry
  for a stalled turn, the system SHALL record one recovery decision under the
  turn lock, mark the original turn `abandoned`, and require a new user message
  rather than replaying incomplete tool activity.
  *Code:* `ChatSessions::RecoverStalledTurn`, `ChatTurnsController#recover`.
  *Test:* `spec/services/chat_sessions/recover_stalled_turn_spec.rb`.
