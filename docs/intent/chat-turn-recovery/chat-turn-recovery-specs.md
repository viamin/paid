---
parent: chat-turn-recovery
prefix: CHAT-TURN-RECOVERY
---

# Chat Turn Recovery EARS Specifications

- [x] **CHAT-TURN-RECOVERY-001** - When an active chat turn has no durable activity for the configured threshold,
  the system shall mark it `stalled` and retain its failure classification.

  *Tests:* `spec/services/chat_sessions/detect_stalled_turns_spec.rb`.

- [x] **CHAT-TURN-RECOVERY-002** - When a chat turn is marked stalled, the system shall append a non-collapsed
  transcript notice explaining that the final response is unknown and that no action was replayed.

  *Tests:* `spec/services/chat_sessions/detect_stalled_turns_spec.rb`, `spec/models/chat_message_spec.rb`.

- [x] **CHAT-TURN-RECOVERY-003** - While a chat session has a pending tool confirmation or an active known
  rate-limit pause, the system shall not classify its active turn as stalled.

  *Tests:* `spec/services/chat_sessions/detect_stalled_turns_spec.rb`.

- [x] **CHAT-TURN-RECOVERY-004** - When a turn is stalled, the system shall not automatically replay its tools or
  fabricate a completed assistant response.

  *Code:* `ChatSessions::DetectStalledTurns`.
