# Chat turn recovery specs

- [x] **CHAT-TURN-001** — When a chat request begins, the system SHALL persist a turn lifecycle record keyed by its transport id and SHALL mark it completed only after a terminal assistant outcome or intentional confirmation pause is durably recorded.
  *Code:* `ChatTurn`, `ChatSessions::SendMessage`, `ChatSessions::ProcessMessageJob`.
  *Test:* `spec/models/chat_turn_spec.rb`.

- [x] **CHAT-TURN-002** — When an unfinished turn has no durable activity beyond the configurable threshold, the system SHALL mark it `stalled`, except while a tool confirmation or a known rate-limit pause is pending.
  *Code:* `ChatTurn#eligible_to_stall?`, `ChatSessions::DetectStalledTurnsJob`.
  *Test:* `spec/models/chat_turn_spec.rb`.

- [x] **CHAT-TURN-003** — When a turn is stalled, the transcript SHALL retain all partial activity and contain one durable notice explaining that its remaining outcome is unknown.
  *Code:* `ChatTurn#create_stall_notice!`, `chat_messages/_turn_stalled_notice.html.erb`.
  *Test:* `spec/models/chat_turn_spec.rb`.

- [x] **CHAT-TURN-004** — Recovery SHALL be row-locked and SHALL not replay a turn after any side-effecting tool completed without an explicit human decision.
  *Code:* `ChatTurn#begin_recovery!`, `ChatMessagesController#recover`.
  *Test:* `spec/models/chat_turn_spec.rb`.
