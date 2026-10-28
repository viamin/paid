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
  result) for that turn; an unpersisted streaming chunk SHALL instead refresh
  a separate, throttled durable attempt heartbeat without becoming a
  transcript checkpoint; before entering the agent loop, the system SHALL
  atomically claim the turn's initial `pending` state so only one overlapping
  delivery can execute it.
  *Code:* `ChatTurn.start!`, `ChatTurn#claim_initial_attempt!`,
  `ChatTurn#record_activity!`, `ChatTurn#heartbeat!`,
  `ChatSessions::SendMessage#on_message_persisted`,
  `ChatSessions::ResolveToolCall#on_message_persisted`.
  *Test:* `spec/models/chat_turn_spec.rb`,
  `spec/services/chat_sessions/send_message_spec.rb`.

## Detection

- [x] **CHAT-TURN-RECOVERY-002** — `ChatTurns::StallDetectorJob` SHALL mark a
  `pending`/`streaming` turn `stalled` once both its `last_activity_at` and
  active-attempt heartbeat are older than the configured threshold
  (`CHAT_TURN_STALL_THRESHOLD_SECONDS`), and
  SHALL NOT mark it stalled — and SHALL NOT represent it as `completed` —
  while a write-tool confirmation belonging to that turn is still pending
  (`ChatTurn#awaiting_confirmation?`); a confirmation belonging to an older
  turn SHALL NOT exempt a newer stale turn.
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
  that infrastructure classification only after positively identifying a
  replay-safe infrastructure failure (never merely because a provider loop
  started); a repeated execution of the same `ProcessMessageJob` that
  encounters its already-claimed turn SHALL write this classification, while
  a separate first-execution duplicate SHALL NOT, and a
  failed recovery SHALL terminate the client stream and replace any in-progress
  recovery notice with a durable failure notice.
  *Code:* `ChatTurn#eligible_for_automatic_recovery?`,
  `ChatSessions::ProcessMessageJob`,
  `ChatTurns::StallDetectorJob#attempt_automatic_recovery`,
  `ChatTurns::Resume`, `ChatTurns::RecoverStalledTurnJob`.
  *Test:* `spec/models/chat_turn_spec.rb`,
  `spec/jobs/chat_turns/stall_detector_job_spec.rb`,
  `spec/services/chat_turns/resume_spec.rb`.

- [x] **CHAT-TURN-RECOVERY-005** — Any stalled turn that has dispatched a
  write tool call, or has exhausted automatic recovery, SHALL require an
  explicit, authenticated human confirmation (the transcript's Resume action)
  before any recovery attempt runs; the queued recovery SHALL recheck that the
  confirming actor still has authority to send messages immediately before
  execution, and if that authority was revoked SHALL NOT call the model and
  SHALL settle and broadcast the denied recovery state — the system SHALL NOT
  automatically replay such a turn.
  *Code:* `app/views/chat_messages/_stalled_turn_notice.html.erb`,
  `ChatChannel#recover_stalled_turn`,
  `ChatTurns::RecoverStalledTurnJob`,
  `app/javascript/controllers/chat_controller.js#resumeStalledTurn`.
  *Test:* `spec/channels/chat_channel_spec.rb`,
  `spec/jobs/chat_turns/recover_stalled_turn_job_spec.rb`.

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
