# EARS Specs: Chat Turn Recovery

> Testable claims for the durable chat turn lifecycle, server-side stall
> detection, the in-transcript stall notice, and bounded recovery (#4680).
> Status markers: `[x]` implemented, `[ ]` gap, `[D]` deferred. Each ID is a
> grep target across specs, tests, and code
> (`grep -r CHAT-TURN-RECOVERY-001`).

- [x] **CHAT-TURN-RECOVERY-001** — When `ChatSessions::SendMessage` opens a
  chat turn, the system SHALL persist a `chat_turns` row bound to the chat
  session and the initiating user message with status `pending`, and SHALL
  advance that row to `streaming` when the turn first writes durable output.

  *Tests:* `spec/services/chat_sessions/turns/open_spec.rb`,
  `spec/services/chat_sessions/send_message_spec.rb`.
  *Code:* `ChatSessions::Turns::Open`, `ChatSessions::SendMessage#call`,
  `ChatTurn#record_activity!`.

- [x] **CHAT-TURN-RECOVERY-002** — When a turn produces a terminal assistant
  message, the system SHALL mark the turn `completed`; when the turn ends
  with a classified error the system SHALL mark it `failed` with that
  classification. A turn SHALL NOT be marked `completed` unless a terminal
  assistant message was persisted for it.

  *Tests:* `spec/services/chat_sessions/send_message_spec.rb`,
  `spec/models/chat_turn_spec.rb`.
  *Code:* `ChatTurn#complete!`, `ChatTurn#fail!`, `ChatSessions::SendMessage#call`.

- [x] **CHAT-TURN-RECOVERY-003** — When the stall detector finds an open turn
  with no durable activity beyond the configured threshold and no terminal
  outcome, the system SHALL mark the turn `stalled` — never `completed` — and
  SHALL record the stall classification and the detection time.

  *Tests:* `spec/services/chat_sessions/turns/detect_stalled_spec.rb`.
  *Code:* `ChatSessions::Turns::DetectStalled`, `ChatTurn#mark_stalled!`.

- [x] **CHAT-TURN-RECOVERY-004** — The stall detector SHALL NOT mark a turn
  stalled while it is awaiting a user confirmation, while its session is
  paused by a provider rate limit, while the turn's token budget is
  exhausted, or while a declared long-running tool call is still in flight.

  *Tests:* `spec/services/chat_sessions/turns/detect_stalled_spec.rb`.
  *Code:* `ChatSessions::Turns::DetectStalled`, `Tools::Registry.long_running?`.

- [x] **CHAT-TURN-RECOVERY-005** — When a turn is classified as stalled, the
  system SHALL persist an in-transcript system notice that states what
  completed, what remains unknown, why the turn needs attention, and offers a
  recovery action, preserving the partial state of the turn.

  *Tests:* `spec/services/chat_sessions/turns/stall_notice_spec.rb`,
  `spec/models/chat_message_spec.rb`.
  *Code:* `ChatSessions::Turns::StallNotice`, `ChatMessage#stalled_turn_notice?`,
  `app/views/chat_messages/_stalled_turn_notice.html.erb`.

- [x] **CHAT-TURN-RECOVERY-006** — Automatic recovery SHALL be limited to
  turns whose failure classification is a classified infrastructure failure,
  whose side-effecting tool calls have not completed, and whose completed
  tools are all declared replay-safe; the number of automatic attempts SHALL
  be bounded by the configured maximum.

  *Tests:* `spec/services/chat_sessions/turns/recover_spec.rb`,
  `spec/mcp/tools/registry_spec.rb`.
  *Code:* `ChatSessions::Turns::Recover`, `Tools::Registry.replay_safe?`.

- [x] **CHAT-TURN-RECOVERY-007** — Recovery SHALL resume from the last
  durable checkpoint by reusing the persisted user message and transcript,
  SHALL NOT dispatch a side-effecting tool call that already completed, and
  SHALL require an explicit approval for any write tool the model requests
  again during the resumed turn.

  *Tests:* `spec/services/chat_sessions/turns/recover_spec.rb`,
  `spec/jobs/chat_sessions/recover_stalled_turn_job_spec.rb`.
  *Code:* `ChatSessions::RecoverStalledTurnJob`, `ChatSessions::SendMessage`,
  `ChatSessions::AgentLoop#auto_approve_eligible?`.

- [x] **CHAT-TURN-RECOVERY-008** — Recovery of an ambiguous stall — a model
  stop, a client disconnect, or a turn whose side-effecting tool calls
  completed — SHALL require an explicit user confirmation, and an unconfirmed
  request SHALL be refused.

  *Tests:* `spec/services/chat_sessions/turns/recover_spec.rb`,
  `spec/requests/chat_turns_spec.rb`.
  *Code:* `ChatSessions::Turns::Recover`, `ChatTurnsController#resume`.

- [x] **CHAT-TURN-RECOVERY-009** — Concurrent or repeated recovery requests
  for the same turn SHALL be deduplicated: at most one recovery may be in
  flight per turn, and a request carrying a stale turn revision SHALL be
  rejected without starting a recovery.

  *Tests:* `spec/services/chat_sessions/turns/recover_spec.rb`,
  `spec/requests/chat_turns_spec.rb`.
  *Code:* `ChatSessions::Turns::Recover`, `ChatTurn#claim_recovery!`.

- [x] **CHAT-TURN-RECOVERY-010** — A recovery request SHALL be
  authorization-aware: only a user authorized to send messages in the chat
  session may resume one of its stalled turns.

  *Tests:* `spec/requests/chat_turns_spec.rb`.
  *Code:* `ChatTurnPolicy`, `ChatTurnsController#resume`.

- [x] **CHAT-TURN-RECOVERY-011** — The system SHALL record an auditable event
  for each stall classification, recovery attempt, recovery outcome, user
  action, duplicate-prevention decision, and abandonment, and those events
  SHALL be queryable per turn and per event type.

  *Tests:* `spec/models/chat_turn_event_spec.rb`,
  `spec/services/chat_sessions/turns/detect_stalled_spec.rb`,
  `spec/services/chat_sessions/turns/recover_spec.rb`.
  *Code:* `ChatTurnEvent`, `ChatSessions::Turns::RecordEvent`.

- [x] **CHAT-TURN-RECOVERY-012** — A turn awaiting a user confirmation that is
  never resolved SHALL be marked `abandoned` once it passes the configured
  abandonment window, and SHALL NOT be marked `stalled`.

  *Tests:* `spec/services/chat_sessions/turns/detect_stalled_spec.rb`.
  *Code:* `ChatSessions::Turns::DetectStalled`, `ChatTurn#abandon!`.
