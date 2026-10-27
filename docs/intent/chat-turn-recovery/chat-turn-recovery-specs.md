# Chat Turn Recovery Specs

- [x] **CHAT-TURN-RECOVERY-001** — When a durable chat turn remains pending or
  streaming beyond the configured inactivity threshold, the server SHALL mark
  it `stalled`, preserve its transcript, and record classification time and an
  auditable stall event without representing the turn as successful.

- [x] **CHAT-TURN-RECOVERY-002** — A turn with a pending tool confirmation or
  a known provider rate-limit pause SHALL NOT be classified as stalled by the
  inactivity sweep.

- [x] **CHAT-TURN-RECOVERY-003** — A stalled turn SHALL render a persistent
  transcript notice explaining that no final assistant response was recorded,
  that partial work is preserved, and that tool actions are not automatically
  repeated.

- [x] **CHAT-TURN-RECOVERY-004** — An authorized user SHALL explicitly claim
  recovery of a stalled turn from its persisted checkpoint. Concurrent or
  repeated requests SHALL record a duplicate-prevention event and SHALL NOT
  start a second recovery.
