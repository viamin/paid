# EARS Specs: Queue diagnosis

- [x] **QUEUE-DIAGNOSIS-001** — When a visible auto-pick project has eligible
  candidates and neither queued nor active work, the system SHALL report
  `runnable_unseeded` with the distinct eligible, queued, and active counts
  and the supported recovery action.

- [x] **QUEUE-DIAGNOSIS-002** — When active work explains an empty waiting
  backlog, the system SHALL report `healthy_active` rather than a failure.

- [x] **QUEUE-DIAGNOSIS-003** — When open work is held by an unresolved
  dependency or feature decision, the system SHALL report `held` and expose
  bounded issue-level blocker provenance without claiming it is runnable.

- [x] **QUEUE-DIAGNOSIS-004** — When scheduling is deliberately paused, the
  system SHALL report `paused`; when diagnostic data cannot be read, it SHALL
  report `unknown` rather than no work.

- [x] **QUEUE-DIAGNOSIS-005** — Dashboard rendering SHALL be read-only; it
  SHALL not enqueue work, perform semantic assessment, execute repositories,
  or mutate remote state.
