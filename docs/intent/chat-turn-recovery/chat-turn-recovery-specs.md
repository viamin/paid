# EARS Specs: Chat Turn Recovery

- [x] **CHAT-TURN-RECOVERY-001** — When Paid accepts a chat message, it SHALL create a durable turn and SHALL record terminal completion, failure, or confirmation pause without representing a missing assistant response as successful.
- [x] **CHAT-TURN-RECOVERY-002** — When a non-terminal turn has no durable activity past the configured threshold, Paid SHALL mark it stalled and persist an in-transcript notice, except when a tool confirmation or provider rate-limit pause is pending.
- [x] **CHAT-TURN-RECOVERY-003** — When a turn is stalled, Paid SHALL preserve its transcript and tool evidence and SHALL not automatically replay the turn or any tool call without a declared replay-safety contract.
