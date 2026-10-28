# Chat Turn Recovery Specs

- [x] **CHAT-TURN-RECOVERY-001** — When a chat request is accepted for
  asynchronous processing, the system SHALL persist a `pending` chat turn
  before enqueuing work and SHALL transition it to `streaming` when processing
  begins.

- [x] **CHAT-TURN-RECOVERY-002** — When a chat turn persists a user,
  tool, or assistant checkpoint, the system SHALL record that checkpoint and
  refresh its durable activity timestamp; when it receives a terminal response
  it SHALL mark the turn completed rather than infer success from client state.

- [x] **CHAT-TURN-RECOVERY-003** — When a pending or streaming chat turn has
  no durable activity beyond the configured stall threshold, the system SHALL
  atomically classify it as `stalled`, record detection time, and preserve its
  transcript evidence; terminal, rate-limited, and pending-confirmation work
  SHALL NOT be classified stalled.

- [x] **CHAT-TURN-RECOVERY-004** — When a turn is classified stalled, the
  transcript SHALL contain an actionable system notice stating that no assistant
  completion was recorded and linking to any unresolved confirmation; the
  notice SHALL NOT represent the turn as successful.

- [D] **CHAT-TURN-RECOVERY-005** — Automatic replay SHALL occur only after a
  retryable infrastructure classification and an idempotency/checkpoint contract
  covers all replayable tools; ambiguous stops and side-effecting evidence SHALL
  require explicit confirmation.
