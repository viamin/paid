# Chat Turn Recovery Specs

- [x] **CHAT-TURN-RECOVERY-001** - When a chat turn remains `pending` or
  `streaming` with no durable activity beyond the configured threshold, the
  system SHALL mark it `stalled`; it SHALL exclude turns awaiting a pending
  tool confirmation and SHALL not mark any stalled turn successful.

- [x] **CHAT-TURN-RECOVERY-002** - When the system marks a chat turn stalled,
  it SHALL preserve the transcript and persist an in-transcript system notice
  identifying the original request and explaining that completed tool calls are
  not replayed automatically.

- [D] **CHAT-TURN-RECOVERY-003** - Before an infrastructure failure receives
  automatic recovery, the recovery path SHALL require a durable checkpoint and
  an idempotency contract for every replayed tool; ambiguous model stops and
  possible side effects SHALL require explicit confirmation.
