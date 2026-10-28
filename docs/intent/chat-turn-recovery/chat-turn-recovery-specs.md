---
parent: PAID
prefix: CHAT-TURN
---

# EARS Specs: Chat Turn Recovery

- [x] **CHAT-TURN-001** — When a chat user message is persisted, the system
  SHALL create or reuse one durable turn and record durable message activity.
- [x] **CHAT-TURN-002** — When a pending or streaming turn has no durable
  activity beyond the configured threshold, the system SHALL atomically mark
  it `stalled` and persist a transcript notice; it SHALL not mark it successful.
- [x] **CHAT-TURN-003** — While a turn awaits confirmation or has a known
  terminal failure, the stall sweep SHALL not classify it as stalled.
- [x] **CHAT-TURN-004** — When an authorized user explicitly confirms recovery
  for a stalled turn with no completed approved tool result, the system SHALL
  resume from its persisted user-message checkpoint and deduplicate concurrent
  attempts; it SHALL not automatically replay arbitrary tools.
