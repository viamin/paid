# EARS Specs: Chat Turn Recovery

- [x] **CHAT-TURN-RECOVERY-001** — When a chat request is accepted, Paid SHALL persist a turn lifecycle and SHALL mark a terminal assistant response completed, a known failure failed, and an explicit confirmation pause non-stalled while preserving every partial transcript row.
- [x] **CHAT-TURN-RECOVERY-002** — When a pending or streaming turn has no durable activity beyond the configured threshold, Paid SHALL atomically classify it as stalled unless it has an active operation lease or pending tool confirmation, and SHALL persist one actionable transcript notice without representing success.
- [x] **CHAT-TURN-RECOVERY-003** — The stalled notice SHALL identify the last durable checkpoint, whether a side-effecting tool completed, that remaining work is unknown, and a recovery action bound to the current turn revision.
- [x] **CHAT-TURN-RECOVERY-004** — When recovery is requested, Paid SHALL resume with the original stream key and persisted checkpoint, require explicit confirmation for ambiguous stops or completed side effects, reauthorize the actor, and reject a stale revision.
- [x] **CHAT-TURN-RECOVERY-005** — Paid SHALL permit at most one bounded automatic recovery for a classified infrastructure failure whose turn has no completed side-effecting tool.
- [x] **CHAT-TURN-RECOVERY-006** — Concurrent or repeated recovery requests SHALL share one active recovery attempt and SHALL NOT dispatch duplicate work.
- [x] **CHAT-TURN-RECOVERY-007** — Paid SHALL retain queryable turn classification, detection time, side-effect completion, recovery attempts, actors, outcomes, and duplicate-prevention events.
