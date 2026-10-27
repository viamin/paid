---
parent: chat-turn-recovery
prefix: CHAT-TURN
---

- [x] `CHAT-TURN-001` When a chat user message is accepted, the system shall persist a turn lifecycle record and shall mark it completed only after a durable assistant response exists.
- [x] `CHAT-TURN-002` When an active turn has no durable activity beyond the configured threshold, the system shall mark it stalled and persist a notice, unless it awaits a user tool confirmation.
- [x] `CHAT-TURN-003` When a turn is stalled, the transcript shall state that prior evidence is preserved, completion is unknown, and a completed side-effecting tool must not be blindly replayed.
