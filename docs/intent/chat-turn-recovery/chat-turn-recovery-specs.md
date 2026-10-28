# EARS Specs: Chat Turn Recovery

- [x] **CHAT-TURN-001** — When a user message is accepted for processing, the
  system SHALL persist a durable chat turn and record state transitions and
  durable activity independently of the streaming client.
- [x] **CHAT-TURN-002** — When a pending or streaming turn has no durable
  activity for fifteen minutes, the system SHALL mark it `stalled` unless it is
  waiting for a tool confirmation or an active rate-limit recovery window.
- [x] **CHAT-TURN-003** — When a turn is marked stalled, the transcript SHALL
  contain one durable notice explaining that partial activity is preserved and
  remaining work is unknown; it SHALL not represent the turn as successful.
- [D] **CHAT-TURN-004** — Automatic replay is deferred until tools declare an
  idempotency/checkpoint contract; ambiguous or side-effecting recovery SHALL
  require explicit authorization.
