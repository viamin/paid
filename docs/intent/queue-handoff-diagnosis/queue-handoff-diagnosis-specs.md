# EARS Specs: Queue Handoff Diagnosis

- [x] **QUEUE-HANDOFF-001** — When a visible Auto-Pick project has an eligible
  issue without a queued or active run for that issue, the dashboard SHALL
  report it as `runnable_not_seeded`, preserving the existing eligibility and
  scheduler data sources and never creating work during rendering, even when
  the queue preview contains unrelated manual, closed-issue, or pull-request
  runs.

- [x] **QUEUE-HANDOFF-002** — When a visible project has active work and no
  eligible issue waiting for a handoff, the dashboard SHALL report
  `active_work`; when it has queued work represented by the queue preview it
  SHALL report `waiting`, including manual, closed-issue, and pull-request
  runs; and when open work has no eligible candidate it SHALL report `held`.

- [x] **QUEUE-HANDOFF-003** — When a project/account or run is deliberately
  paused, the dashboard SHALL report `paused` without treating the pause as a
  stall. If diagnostic evaluation fails, it SHALL expose `unknown` coverage
  and a refresh action rather than claim that the queue has no work.

- [x] **QUEUE-HANDOFF-004** — When a visible project is `held` because an
  open issue has one or more blocking dependencies or a delivery decision
  hold, the dashboard SHALL identify the held issue, every blocking work item
  or external dependency, and the existing supported recovery route; it SHALL
  not infer that a summarized admission control is a human decision.
