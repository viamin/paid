# EARS Specs: Chat Turn Recovery

- [x] **CHAT-TURN-RECOVERY-001** — When a chat request persists its user
  message, the system SHALL maintain a durable turn lifecycle and SHALL record
  durable activity, terminal outcome, and messages produced by that turn.

- [x] **CHAT-TURN-RECOVERY-002** — When a pending or streaming turn has no
  durable activity beyond the configured threshold, the detector SHALL
  atomically classify it as stalled without representing it as successful.

- [x] **CHAT-TURN-RECOVERY-003** — While a turn awaits explicit tool
  confirmation or a known rate-limit recovery, the detector SHALL exclude it
  from stall classification.

- [x] **CHAT-TURN-RECOVERY-004** — When a turn becomes stalled, the transcript
  SHALL contain one durable actionable notice describing preserved evidence,
  unknown outcome, side-effect status, and the explicit recovery action.

- [x] **CHAT-TURN-RECOVERY-005** — When an authorized user resumes a stalled
  turn at its current revision, the system SHALL continue from the original
  durable transcript checkpoint and SHALL NOT insert another user message.

- [x] **CHAT-TURN-RECOVERY-006** — When recovery is requested concurrently or
  repeatedly for the same turn revision, the system SHALL enqueue at most one
  attempt and SHALL audit duplicate-prevention events.

- [x] **CHAT-TURN-RECOVERY-007** — When a recovery attempt proceeds or ends,
  the system SHALL retain queryable classification, actor, detection time,
  side-effect evidence, attempt outcome, and duplicate-prevention count.

- [D] **CHAT-TURN-RECOVERY-008** — Where an infrastructure failure and every
  replayable tool have an explicit idempotency contract, the system SHALL
  permit a bounded automatic checkpoint recovery. Automatic recovery remains
  disabled until those contracts are implemented.
