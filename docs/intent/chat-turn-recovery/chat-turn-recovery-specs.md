# EARS Specs: Chat Turn Recovery

- [x] **CHAT-TURN-RECOVERY-001** — When a chat user message is accepted, the
  system SHALL create a durable `ChatTurn` checkpoint and SHALL move it to a
  terminal completed, failed, or awaiting-confirmation state rather than
  inferring completion from browser streaming state.

- [x] **CHAT-TURN-RECOVERY-002** — When a pending or streaming chat turn has no
  durable activity for the configured inactivity threshold, the detector SHALL
  mark it stalled under a row lock and SHALL persist one non-success transcript
  notice that identifies preserved partial tool evidence and pending
  confirmations.

- [x] **CHAT-TURN-RECOVERY-003** — A turn awaiting user confirmation, a
  completed/failed turn, or a turn refreshed concurrently with detection SHALL
  NOT be classified as stalled.

- [x] **CHAT-TURN-RECOVERY-004** — When a user requests recovery for a stalled
  turn, the system SHALL record the request at most once and SHALL NOT replay a
  model request or tool call automatically.
