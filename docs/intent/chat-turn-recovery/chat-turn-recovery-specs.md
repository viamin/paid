# Chat Turn Recovery Specs

- [x] **CHAT-TURN-RECOVERY-001** — When a chat request is accepted, the system
  SHALL persist a pending turn identified by its stream identifier before its
  asynchronous work is enqueued.

- [x] **CHAT-TURN-RECOVERY-002** — When a pending or streaming turn has no
  durable activity beyond the configured threshold, the system SHALL atomically
  mark it stalled and persist a non-success system notice in its transcript.

- [x] **CHAT-TURN-RECOVERY-003** — The stall sweep SHALL not classify a turn
  as stalled while its transcript has a pending tool confirmation or its
  session has a known provider rate-limit recovery window.

- [x] **CHAT-TURN-RECOVERY-004** — When a chat turn completes or fails through
  a known job outcome, the system SHALL persist that terminal lifecycle state
  rather than leaving it pending or streaming.
