# EARS Specs: Chat Turn Recovery

- [x] **CHAT-TURN-RECOVERY-001** — When a `pending` or `streaming` chat turn
  has no durable activity for the configured detection threshold, the system
  SHALL mark it `stalled` and SHALL not represent it as completed.
  *Test:* `spec/services/chat_turns/detect_stalls_spec.rb`.
  *Code:* `ChatTurns::DetectStalls`, `ChatTurn`.

- [x] **CHAT-TURN-RECOVERY-002** — When a turn is awaiting a write-tool
  confirmation or its session has a recorded rate-limit recovery window, the
  detector SHALL not classify it as stalled.
  *Test:* `spec/services/chat_turns/detect_stalls_spec.rb`.
  *Code:* `ChatTurns::DetectStalls`.

- [x] **CHAT-TURN-RECOVERY-003** — When a turn is classified as stalled, the
  transcript SHALL retain an actionable notice identifying the last durable
  checkpoint and stating that unfinished actions are unknown.
  *Test:* `spec/services/chat_turns/detect_stalls_spec.rb`.
  *Code:* `ChatTurns::DetectStalls`, `ChatMessage#chat_turn_stalled_notice?`.

- [x] **CHAT-TURN-RECOVERY-005** — When duplicate delivery uses the same
  browser stream identifier, the system SHALL allow only one worker to claim
  and execute the turn; confirmation resolution SHALL continue and complete
  the originating turn rather than creating an unrelated lifecycle.
  *Test:* `spec/services/chat_sessions/send_message_spec.rb`,
  `spec/services/chat_sessions/resolve_tool_call_spec.rb`.
  *Code:* `ChatTurn#claim_processing!`, `ChatSessions::ResolveToolCall`.

- [D] **CHAT-TURN-RECOVERY-004** — Automatic replay remains deferred until a
  tool declares an idempotency/checkpoint contract. Recovery of an ambiguous
  model stop or any possible side effect requires an explicit, deduplicated,
  authorized user action.
