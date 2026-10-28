# EARS Specs: Chat Turn Recovery

- [x] **CHAT-TURN-001** — When an unfinished chat turn has no durable activity
  for the configured stall timeout, the system SHALL mark it `stalled` and
  retain its transcript rather than representing it as successful.

- [x] **CHAT-TURN-002** — When a chat turn is awaiting a tool confirmation or
  has a declared active long-running deadline, the stall detector SHALL leave it
  unfinished.

- [x] **CHAT-TURN-003** — When a turn is classified stalled, the transcript
  SHALL contain a durable system notice explaining that work may be incomplete
  and directing the user to preserved request/tool evidence before retrying.

- [D] **CHAT-TURN-004** — Automatic recovery SHALL run only under a bounded,
  idempotent replay contract; ambiguous or side-effecting recovery requires
  explicit user confirmation.
