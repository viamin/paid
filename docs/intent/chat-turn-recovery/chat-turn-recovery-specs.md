# EARS Specs: Chat Turn Recovery

- [x] **CHAT-TURN-001** — When a user message is durably accepted for chat processing, the system SHALL create a durable turn lifecycle record and SHALL not infer successful completion from the user message alone.
- [x] **CHAT-TURN-002** — When an active chat turn has no durable activity for the configured stall threshold, the system SHALL atomically mark it `stalled`, record its classification and detection evidence, and SHALL not mark it completed.
- [x] **CHAT-TURN-003** — When a turn is awaiting a tool confirmation or a known runner rate-limit recovery window, the system SHALL not classify it as stalled.
- [x] **CHAT-TURN-004** — When a turn is classified as stalled, the system SHALL preserve its transcript and append a durable notice warning that partial tool activity may have completed and must not be blindly replayed.
