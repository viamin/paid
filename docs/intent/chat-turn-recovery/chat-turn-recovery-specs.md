# EARS Specs: Chat Turn Recovery

- [x] **CHAT-TURN-001** — When a user message starts a chat turn, the system SHALL persist a turn lifecycle record and move it to `streaming` before model work begins.

- [x] **CHAT-TURN-002** — When a streaming turn exceeds its configured durable-activity timeout, the system SHALL atomically mark it `stalled` and persist an explanatory transcript notice, unless the session is rate-limited or has a pending tool confirmation.

- [x] **CHAT-TURN-003** — When a turn is stalled, the transcript SHALL state that the partial evidence was preserved and that tools are not replayed automatically, and SHALL offer an authorized recovery action.

- [x] **CHAT-TURN-004** — When an authorized user explicitly requests recovery of a stalled turn, the system SHALL deduplicate concurrent requests and resume from the durable transcript without dispatching stored tool calls.

- [x] **CHAT-TURN-005** — The system SHALL record queryable turn classification, detection, recovery request, recovery outcome, and duplicate-prevention events.
