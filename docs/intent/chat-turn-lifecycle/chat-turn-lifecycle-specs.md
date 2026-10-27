# Chat Turn Lifecycle Specs

> Testable claims for durable chat turn lifecycle, stall detection, and safe
> recovery. Status markers: `[x]` implemented, `[ ]` gap, `[D]` deferred.

- [x] **CHAT-TURN-LIFECYCLE-001** — When a chat turn is started, the system
  SHALL persist a durable turn record with lifecycle status `pending`, link the
  persisted user message to it, and advance the turn's durable activity
  timestamp on every artifact the turn produces.

  *Tests:* `spec/services/chat_turns/start_spec.rb`,
  `spec/models/chat_turn_spec.rb`.
  *Code:* `ChatTurns::Start`, `ChatTurn#record_activity!`,
  `ChatSessions::SendMessage#persist_user_message`,
  `ChatSessions::AgentLoop#track_created_message`.

- [x] **CHAT-TURN-LIFECYCLE-002** — When a turn produces a terminal assistant
  response, the system SHALL mark the turn `completed`; when the turn ends in a
  classified error (provider, budget, transport), the system SHALL mark the
  turn `failed` and record the failure classification. A stalled turn SHALL
  never be marked successful.

  *Tests:* `spec/services/chat_turns/start_spec.rb`,
  `spec/models/chat_turn_spec.rb`.
  *Code:* `ChatTurn#mark_completed!`, `ChatTurn#mark_failed!`,
  `ChatTurns::FailureClassification`.

- [x] **CHAT-TURN-LIFECYCLE-003** — When a turn has no durable activity beyond
  the configured stall threshold and no terminal outcome, the system SHALL
  detect it and mark the turn `stalled` with the detection time and the stall
  classification, preserving the transcript and the partial evidence.

  *Tests:* `spec/services/chat_turns/detect_stalls_spec.rb`.
  *Code:* `ChatTurns::DetectStalls`, `ChatTurn#mark_stalled!`,
  `ChatTurns::DetectStalledTurnsJob`.

- [x] **CHAT-TURN-LIFECYCLE-004** — A turn awaiting a write-tool confirmation
  and a turn inside a known long-running operation SHALL NOT be classified as
  stalled.

  *Tests:* `spec/services/chat_turns/detect_stalls_spec.rb`.
  *Code:* `ChatTurns::DetectStalls#classify`,
  `ChatTurns::Classify::LONG_RUNNING_OPERATION`.

- [x] **CHAT-TURN-LIFECYCLE-005** — When a turn is classified as stalled, the
  system SHALL render an in-transcript system notice that states what
  completed, what remains unknown, why the turn needs attention, links the
  pending tool confirmations, and offers a recovery action.

  *Tests:* `spec/services/chat_turns/stall_notice_spec.rb`,
  `spec/models/chat_message_spec.rb`.
  *Code:* `ChatTurns::StallNotice`, `ChatMessage#stall_notice?`,
  `app/views/chat_messages/_stall_notice.html.erb`.

- [x] **CHAT-TURN-LIFECYCLE-006** — The system SHALL apply bounded automatic
  recovery only to classifications that are opted in for automatic recovery
  and only when the replay-safety contract permits it: no side-effecting tool
  completed inside the turn, every dispatched tool is replay-safe, and no
  confirmation is pending.

  *Tests:* `spec/services/chat_turns/replay_safety_spec.rb`,
  `spec/services/chat_turns/detect_stalls_spec.rb`.
  *Code:* `ChatTurns::ReplaySafety`, `Tools::Registry.replay_safe?`,
  `TenantSetting#chat_turn_auto_recovery_classifications`.

- [x] **CHAT-TURN-LIFECYCLE-007** — Recovery SHALL require explicit user
  confirmation when the stall classification is ambiguous (a model stop or a
  client disconnect) or when a side-effecting tool already completed inside
  the turn, and SHALL NOT blindly replay side-effecting tool calls.

  *Tests:* `spec/services/chat_turns/request_recovery_spec.rb`.
  *Code:* `ChatTurns::RequestRecovery`, `ChatTurns::ReplaySafety`.

- [x] **CHAT-TURN-LIFECYCLE-008** — Recovery SHALL resume the turn from the
  last durable checkpoint instead of replaying the whole turn: tool calls that
  already produced a result stay in the persisted transcript and are not
  dispatched again.

  *Tests:* `spec/services/chat_turns/recover_spec.rb`.
  *Code:* `ChatTurns::Recover`, `ChatSessions::AgentLoop#build_conversation`.

- [x] **CHAT-TURN-LIFECYCLE-009** — Concurrent or repeated recovery requests
  for the same turn SHALL be deduplicated: at most one recovery runs, and every
  rejected duplicate is recorded as a duplicate-prevention event.

  *Tests:* `spec/services/chat_turns/request_recovery_spec.rb`,
  `spec/jobs/chat_turns/recover_turn_job_spec.rb`.
  *Code:* `ChatTurns::RequestRecovery`, `ChatTurns::RecoverTurnJob`,
  `ChatTurn#claim_recovery!`.

- [x] **CHAT-TURN-LIFECYCLE-010** — A recovery request SHALL be
  revision- and authorization-aware: a request naming a turn that already
  reached a terminal status SHALL be rejected as stale, and a request from an
  actor who cannot see the session SHALL be rejected.

  *Tests:* `spec/requests/chat_turns_spec.rb`.
  *Code:* `ChatTurnsController#recover`, `ChatSessionPolicy`.

- [x] **CHAT-TURN-LIFECYCLE-011** — The system SHALL record an auditable
  event for every stall classification and detection, every recovery attempt
  and its outcome, every user action, and every duplicate-prevention event,
  including whether side-effecting tools had completed, so that stall rate,
  recovery success rate, and abandoned-turn rate are queryable.

  *Tests:* `spec/models/chat_turn_event_spec.rb`,
  `spec/services/chat_turns/detect_stalls_spec.rb`.
  *Code:* `ChatTurnEvent`, `ChatTurns::RecordEvent`.
