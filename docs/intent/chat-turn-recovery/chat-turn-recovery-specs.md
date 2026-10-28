# Chat Turn Recovery Specs

- [x] **CHAT-TURN-RECOVERY-001** - When a user message starts an interactive
  chat turn, the system SHALL persist one durable turn lifecycle and update its
  activity timestamp from later persisted turn messages.

- [x] **CHAT-TURN-RECOVERY-002** - When a turn produces a final assistant
  response, or resolves its pending confirmation into one, the system SHALL
  mark that turn completed; a turn without that response SHALL not be marked
  successful.

- [x] **CHAT-TURN-RECOVERY-003** - When a known token or provider failure ends
  a turn, the system SHALL retain the transcript and record a failed outcome.

- [x] **CHAT-TURN-RECOVERY-004** - When an open turn has no durable activity
  beyond its configured threshold, the system SHALL classify it durably as
  stalled or abandoned unless a known waiting or terminal condition applies.

- [x] **CHAT-TURN-RECOVERY-005** - When a turn is awaiting a tool confirmation,
  the detector SHALL leave it open and SHALL not classify it as stalled.

- [x] **CHAT-TURN-RECOVERY-006** - When a turn is awaiting a declared
  long-running tool, is rate limited, or has an existing budget/provider
  outcome, the detector SHALL preserve that specific state rather than report a
  generic stall.

- [x] **CHAT-TURN-RECOVERY-007** - When a turn is classified as stalled or
  abandoned, the transcript SHALL show one persistent notice explaining the
  recorded work, unknown outcome, classification, and safe recovery action.

- [x] **CHAT-TURN-RECOVERY-008** - The system SHALL automatically recover only
  opted-in infrastructure failures that satisfy the replay-safety contract and
  bounded recovery budget.

- [x] **CHAT-TURN-RECOVERY-009** - A recovery of an ambiguous stop or a turn
  with completed side-effecting tools SHALL require an explicit authorized user
  action.

- [x] **CHAT-TURN-RECOVERY-010** - When a turn resumes, the system SHALL reuse
  durable tool results and SHALL not dispatch a matching completed write tool.

- [x] **CHAT-TURN-RECOVERY-011** - Concurrent or repeated recovery requests
  SHALL claim at most one active recovery and SHALL record prevented duplicates.

- [x] **CHAT-TURN-RECOVERY-012** - The recovery endpoint SHALL require chat
  authorization and SHALL reject a stale notice revision.

- [x] **CHAT-TURN-RECOVERY-013** - The system SHALL retain queryable events for
  classification, detection, recovery request and outcome, user action,
  completed side effects, and duplicate prevention.
