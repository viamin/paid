---
parent: PAID
prefix: CHAT-TURN-RECOVERY
---

# Chat Turn Recovery EARS Specs

- [x] **CHAT-TURN-RECOVERY-001** — When Paid accepts a chat message, the system SHALL create a durable turn with a non-terminal lifecycle state and a durable activity checkpoint.
- [x] **CHAT-TURN-RECOVERY-002** — When a non-terminal turn has no durable activity for the configured timeout, the system SHALL mark it `stalled`, preserve its partial evidence, and append a transcript notice; it SHALL NOT mark that turn completed.
- [x] **CHAT-TURN-RECOVERY-003** — When a turn is awaiting tool confirmation, rate-limit recovery, or a declared long-running checkpoint, the system SHALL NOT classify it as stalled.
- [ ] **CHAT-TURN-RECOVERY-004** — When a user requests recovery for a stalled turn, the system SHALL authorize and serialize the request, record the attempt, and require that explicit action before dispatching any replay.
