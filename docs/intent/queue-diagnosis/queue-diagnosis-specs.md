# EARS Specs: Queue Diagnosis

- [x] **QUEUE-DIAGNOSIS-001** — When the Upcoming Queue is rendered empty, the system SHALL distinguish canonical eligible candidates, scheduler-queued runs, active runs, mechanical holds, and paused admission controls; it SHALL report `runnable_unseeded`, `healthy_active_work`, `genuine_holds`, `resource_policy_paused`, or `healthy_no_waiting_work` as applicable rather than treating every empty queue as a failure.

- [x] **QUEUE-DIAGNOSIS-002** — When the live scheduler has queued work but the rendered queue is empty, the system SHALL report `stale_dashboard` with a refresh action; a diagnostic query failure SHALL report `unknown` with a refresh action and SHALL NOT assert that no work exists.

- [x] **QUEUE-DIAGNOSIS-003** — The diagnosis SHALL expose bounded, inspectable issue-level mechanical blocker provenance, preserving multiple blockers per issue and the distinction between candidate eligibility and queued or active work.

- [x] **QUEUE-DIAGNOSIS-004** — Dashboard diagnosis SHALL be read-only: it SHALL NOT invoke LLMs, execute repository code, or mutate local or remote state. Authorized handoff recovery remains in the existing event-driven and periodic eligibility sweep paths.
