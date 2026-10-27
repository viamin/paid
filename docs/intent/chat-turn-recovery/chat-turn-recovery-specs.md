# EARS Specs: Durable Chat Turn Recovery

- [x] **CHAT-TURN-001** — When a pending or streaming chat turn has no durable
  activity beyond the configured threshold, Paid SHALL classify it as stalled,
  and SHALL NOT represent it as successful.

- [x] **CHAT-TURN-002** — When an otherwise inactive chat turn awaits an
  explicit tool confirmation, a recorded rate-limit reset, or a declared
  long-running operation, Paid SHALL NOT classify it as stalled.

- [x] **CHAT-TURN-003** — When Paid classifies a chat turn as stalled, it SHALL
  preserve the transcript and persist one in-transcript system notice that
  explains that the final outcome is unknown and directs the user to the
  preserved tool evidence.

- [x] **CHAT-TURN-004** — When a stalled turn has no non-system durable
  activity after its user checkpoint, Paid SHALL permit one bounded recovery by
  re-enqueuing that checkpoint rather than creating a new user message.

- [x] **CHAT-TURN-005** — When a stalled turn has tool activity after its
  checkpoint, Paid SHALL require user review and SHALL NOT replay it
  automatically or through the safe-retry action.

- [x] **CHAT-TURN-006** — When recovery is requested, Paid SHALL require the
  current turn revision and atomically claim the stalled turn so concurrent or
  repeated requests cannot enqueue duplicate recovery work.

- [x] **CHAT-TURN-007** — When a turn is classified or recovery is attempted,
  Paid SHALL record queryable lifecycle timestamps and structured audit fields
  including the classification, outcome, attempt count, and whether tool
  activity had completed.
