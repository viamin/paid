# Chat Turn Stall Recovery Specs

> Testable claims for interactive chat turn stall detection and recovery.
> Status markers: `[x]` implemented, `[ ]` gap, `[D]` deferred.

- [x] **CHAT-TURN-STALL-001** - The system SHALL persist a durable chat turn
  record for every persisted user message, carrying the turn's lifecycle status
  (`pending`, `streaming`, `completed`, `failed`, `stalled`, `abandoned`), the
  last durable activity timestamp, and the durable checkpoint message, and a
  turn with partial durable activity and no terminal outcome SHALL NOT be
  recorded as successful.

  *Tests:* `spec/models/chat_turn_spec.rb`,
  `spec/services/chat_sessions/turns/detect_stalled_spec.rb`.
  *Code:* `app/models/chat_turn.rb`, `app/services/chat_sessions/turns/open.rb`,
  `app/services/chat_sessions/turns/complete.rb`,
  `app/services/chat_sessions/turns/fail.rb`.

- [x] **CHAT-TURN-STALL-002** - The system SHALL mark a chat turn `stalled`
  when no durable activity has been recorded on it for longer than the
  account's configured stall threshold, and SHALL record the detection time
  and the stall classification on the turn.

  *Tests:* `spec/services/chat_sessions/turns/detect_stalled_spec.rb`.
  *Code:* `app/services/chat_sessions/turns/detect_stalled.rb`,
  `app/jobs/chat_sessions/turns/detect_stalled_job.rb`.

- [x] **CHAT-TURN-STALL-003** - The system SHALL classify a stalled chat turn
  from durable evidence into exactly one of `infrastructure_failure`,
  `provider_timeout`, `budget_exhausted`, `client_disconnect`, or `model_stop`,
  and SHALL treat a turn with no recorded failure and no recorded client
  disconnect as the ambiguous `model_stop` classification.

  *Tests:* `spec/services/chat_sessions/turns/detect_stalled_spec.rb`.
  *Code:* `app/services/chat_sessions/turns/classify.rb`.

- [x] **CHAT-TURN-STALL-004** - The system SHALL NOT mark a chat turn stalled
  while the turn is awaiting a write-tool confirmation, while the session is
  paused on a provider rate-limit window, while the session is archived or
  closed, or while the turn's in-flight tool is declared long-running.

  *Tests:* `spec/services/chat_sessions/turns/detect_stalled_spec.rb`.
  *Code:* `app/services/chat_sessions/turns/detect_stalled.rb`,
  `app/mcp/tools/base_tool.rb`.

- [x] **CHAT-TURN-STALL-005** - The system SHALL render an in-transcript notice
  for a stalled chat turn that states what completed, what remains unknown, and
  why the turn needs attention, and SHALL preserve the partial tool evidence
  the turn produced.

  *Tests:* `spec/services/chat_sessions/turns/stall_notice_spec.rb`,
  `spec/models/chat_message_spec.rb`.
  *Code:* `app/services/chat_sessions/turns/stall_notice.rb`,
  `app/models/chat_message.rb`,
  `app/views/chat_messages/_stalled_turn_notice.html.erb`.

- [x] **CHAT-TURN-STALL-006** - The system SHALL apply automatic recovery to a
  stalled chat turn only when the account's automatic-recovery opt-in list
  contains the turn's classification, the turn has consumed fewer than the
  bounded attempt limit, and no side-effecting tool is in flight without a
  persisted result; a tool that has not declared itself replay-safe SHALL
  prevent automatic recovery.

  *Tests:* `spec/services/chat_sessions/turns/recover_spec.rb`,
  `spec/services/chat_sessions/turns/replay_safety_spec.rb`.
  *Code:* `app/services/chat_sessions/turns/replay_safety.rb`,
  `app/mcp/tools/base_tool.rb`, `app/mcp/tools/registry.rb`.

- [x] **CHAT-TURN-STALL-007** - The system SHALL require an explicit
  confirmation to recover a chat turn whose classification is not eligible for
  automatic recovery, including an ambiguous `model_stop`, and SHALL NOT
  replay a side-effecting tool call that has already completed.

  *Tests:* `spec/services/chat_sessions/turns/recover_spec.rb`.
  *Code:* `app/services/chat_sessions/turns/recover.rb`,
  `app/controllers/chat_turns_controller.rb`.

- [x] **CHAT-TURN-STALL-008** - The system SHALL deduplicate concurrent or
  repeated recovery requests for the same chat turn, SHALL record a
  duplicate-prevention event when a request is rejected as a duplicate, and
  SHALL recognise a repeated request that carries an already-used idempotency
  key as a duplicate.

  *Tests:* `spec/services/chat_sessions/turns/recover_spec.rb`.
  *Code:* `app/services/chat_sessions/turns/recover.rb`,
  `app/models/chat_turn_event.rb`.

- [x] **CHAT-TURN-STALL-009** - The system SHALL reject a recovery request
  whose revision token no longer matches the chat turn's current revision, and
  SHALL refuse a recovery request from an actor who is not authorized to act
  on the chat session.

  *Tests:* `spec/services/chat_sessions/turns/recover_spec.rb`,
  `spec/controllers/chat_turns_controller_spec.rb`.
  *Code:* `app/services/chat_sessions/turns/recover.rb`,
  `app/controllers/chat_turns_controller.rb`.

- [x] **CHAT-TURN-STALL-010** - The system SHALL record the stall
  classification, the detection time, every recovery attempt and its outcome,
  the user action that triggered a recovery, and whether side-effecting tools
  had completed, so that stall rate, recovery success rate, abandoned-turn
  rate, and duplicate-prevention events are queryable.

  *Tests:* `spec/models/chat_turn_event_spec.rb`,
  `spec/services/chat_sessions/turns/detect_stalled_spec.rb`.
  *Code:* `app/models/chat_turn_event.rb`,
  `app/services/chat_sessions/turns/record_event.rb`.

- [x] **CHAT-TURN-STALL-011** - The system SHALL resume a stalled chat turn
  from its last durable checkpoint by continuing the agent loop over the
  persisted transcript, and SHALL NOT re-dispatch a tool call whose result is
  already persisted in the transcript.

  *Tests:* `spec/services/chat_sessions/turns/recover_spec.rb`.
  *Code:* `app/services/chat_sessions/turns/recover.rb`,
  `app/services/chat_sessions/agent_loop.rb`.

- [x] **CHAT-TURN-STALL-012** - The system SHALL publish a blocking `error`
  notification for a stalled chat turn that is not eligible for automatic
  recovery, so that a halted turn is never legible only in the database.

  *Tests:* `spec/services/chat_sessions/turns/detect_stalled_spec.rb`.
  *Code:* `app/services/chat_sessions/turns/detect_stalled.rb`.
