# EARS Specs: Chat Turn Stall Detection and Recovery

> Testable claims for issue #4680. Status markers: `[x]` implemented ·
> `[ ]` active gap · `[D]` deferred. Each ID is a grep target
> (`grep -r CHAT-TURN-RECOVERY-001`).

## Durable turn state

- [x] **CHAT-TURN-RECOVERY-001** — When `ChatSessions::SendMessage` persists
  the triggering user message for a turn, the system SHALL create (or, for a
  retried same-message attempt, reuse) a durable `ChatTurn` row keyed to that
  message, and SHALL bump its `last_activity_at` checkpoint on every
  subsequently persisted message (user, assistant, tool call, or tool
  result) for that turn — never on an unpersisted streaming chunk.
  *Code:* `ChatTurn.start!`, `ChatTurn#record_activity!`,
  `ChatSessions::SendMessage#on_message_persisted`,
  `ChatSessions::ResolveToolCall#on_message_persisted`.
  *Test:* `spec/models/chat_turn_spec.rb`,
  `spec/services/chat_sessions/send_message_spec.rb`.

## Detection

- [x] **CHAT-TURN-RECOVERY-002** — `ChatTurns::StallDetectorJob` SHALL mark a
  `pending`/`streaming` turn `stalled` once its `last_activity_at` is older
  than the configured threshold (`CHAT_TURN_STALL_THRESHOLD_SECONDS`), and
  SHALL NOT mark it stalled — and SHALL NOT represent it as `completed` —
  while a write-tool confirmation on its session is still pending
  (`ChatTurn#awaiting_confirmation?`).
  *Code:* `ChatTurns::StallDetectorJob#recover_or_notify`.
  *Test:* `spec/jobs/chat_turns/stall_detector_job_spec.rb`.

## Transcript notification

- [x] **CHAT-TURN-RECOVERY-003** — When a turn is marked `stalled`, the
  system SHALL persist a durable, non-collapsed system `ChatMessage`
  (`stalled_turn_notice?`) explaining what is known (whether a write tool had
  started) and what remains unknown, and SHALL broadcast it to the session's
  live stream.
  *Code:* `ChatMessage#stalled_turn_notice?`, `ChatMessage#transcript_notice?`,
  `ChatTurns::StalledTurnNoticeMessage`, `ChatTurns::PersistStallNotice`,
  `app/views/chat_messages/_stalled_turn_notice.html.erb`.
  *Test:* `spec/models/chat_message_spec.rb`,
  `spec/jobs/chat_turns/stall_detector_job_spec.rb`.

## Safe recovery

- [x] **CHAT-TURN-RECOVERY-004** — The system SHALL attempt bounded,
  unconfirmed automatic recovery for a stalled turn only when its durable
  `recovery_classification` is `infrastructure_failure`, it has never
  dispatched a write tool call (`write_tool_dispatched == false`), and it has
  not exceeded `ChatTurn::MAX_AUTOMATIC_RECOVERY_ATTEMPTS`; recovery SHALL
  resume from the turn's last durable checkpoint (the persisted conversation)
  rather than replaying the triggering message; the system SHALL durably write
  that infrastructure classification before entering the provider loop, and a
  failed recovery SHALL terminate the client stream and replace any in-progress
  recovery notice with a durable failure notice.
  *Code:* `ChatTurn#eligible_for_automatic_recovery?`,
  `ChatTurns::StallDetectorJob#attempt_automatic_recovery`,
  `ChatTurns::Resume`, `ChatTurns::RecoverStalledTurnJob`.
  *Test:* `spec/models/chat_turn_spec.rb`,
  `spec/jobs/chat_turns/stall_detector_job_spec.rb`,
  `spec/services/chat_turns/resume_spec.rb`.

- [x] **CHAT-TURN-RECOVERY-005** — Any stalled turn that has dispatched a
  write tool call, or has exhausted automatic recovery, SHALL require an
  explicit, authenticated human confirmation (the transcript's Resume action)
  before any recovery attempt runs — the system SHALL NOT automatically
  replay such a turn.
  *Code:* `app/views/chat_messages/_stalled_turn_notice.html.erb`,
  `ChatChannel#recover_stalled_turn`,
  `app/javascript/controllers/chat_controller.js#resumeStalledTurn`.
  *Test:* `spec/channels/chat_channel_spec.rb`.

- [x] **CHAT-TURN-RECOVERY-006** — The system SHALL deduplicate concurrent or
  repeated recovery requests for the same turn: `ChatTurn#claim_recovery!`
  SHALL transition the turn from `stalled` to `streaming` via a single
  compare-and-swap, so at most one of any concurrent automatic/manual
  recovery attempts proceeds, and SHALL bound total recovery attempts
  (automatic + manual) at `ChatTurn::MAX_RECOVERY_ATTEMPTS` before moving the
  turn to a terminal `abandoned` state.
  *Code:* `ChatTurn#claim_recovery!`, `ChatTurn#recovery_exhausted?`.
  *Test:* `spec/models/chat_turn_spec.rb`,
  `spec/channels/chat_channel_spec.rb`.

## Observability

- [x] **CHAT-TURN-RECOVERY-007** — The system SHALL record an auditable,
  queryable `ChatTurnLifecycleEvent` for every stall classification,
  recovery attempt (including a rejected duplicate), completion, and failure,
  each carrying `chat_turn_id`, `chat_session_id`, the acting user when
  human-initiated, and event-specific metadata — and a failure writing this
  audit trail SHALL NOT abort the turn-lifecycle transition that triggered
  it.
  *Code:* `ChatTurnLifecycleEvent`, `ChatTurns::Lifecycle.record`.
  *Test:* `spec/models/chat_turn_spec.rb`.
