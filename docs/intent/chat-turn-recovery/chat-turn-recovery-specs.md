# Chat Turn Recovery Specs

- [x] **CHAT-TURN-RECOVERY-001** - When an accepted chat request persists its
  user-message checkpoint, the system SHALL persist a turn in `streaming`
  state and SHALL mark it `completed`, `failed`, or `awaiting_confirmation`
  only from a durable server-side outcome.

- [x] **CHAT-TURN-RECOVERY-002** - When a nonterminal chat turn has no durable
  activity beyond the configured threshold, the detector SHALL mark it
  `stalled` and persist one transcript system notice describing the preserved
  checkpoint and whether tool activity is known.

- [x] **CHAT-TURN-RECOVERY-003** - The detector SHALL not mark a turn stalled
  while a tool confirmation is pending or while it has durable activity inside
  the threshold.

- [x] **CHAT-TURN-RECOVERY-004** - The system SHALL schedule at most one
  automatic recovery for an infrastructure-stalled turn only when no tool
  request or result was durably recorded after its checkpoint; all other
  recoveries require an explicit authorized action.
