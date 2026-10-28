# EARS Specs: Chat Turn Recovery

- [x] **CHAT-TURN-001** — When a chat user message is persisted, the system
  SHALL persist a durable turn and mark it completed only after a terminal
  assistant response is saved, or pending when a tool confirmation is awaited.

- [x] **CHAT-TURN-002** — When a streaming chat turn has no durable activity
  beyond the configured threshold, the system SHALL mark it stalled and append
  a transcript notice that preserves the unknown outcome; turns waiting on a
  rate limit or tool confirmation SHALL not be marked stalled.
