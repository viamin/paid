# EARS Specs: Queue Handoff Diagnosis

- [x] **QUEUE-HANDOFF-001** — When a visible Auto-Pick project has an eligible
  issue without a queued or active run for that issue, the dashboard SHALL
  report it as `runnable_not_seeded`, preserving the existing eligibility and
  scheduler data sources and never creating work during rendering.

- [x] **QUEUE-HANDOFF-002** — When a visible project has active work and no
  eligible issue waiting for a handoff, the dashboard SHALL report
  `active_work`; when it has queued eligible work it SHALL report `waiting`;
  and when open work has no eligible candidate it SHALL report `held`.

- [x] **QUEUE-HANDOFF-003** — When a project/account is deliberately paused,
  the dashboard SHALL report `paused` without treating the pause as a stall.
  If diagnostic evaluation fails, it SHALL expose `unknown` coverage and a
  refresh action rather than claim that the queue has no work.

