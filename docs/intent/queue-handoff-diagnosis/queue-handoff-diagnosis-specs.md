# EARS Specs: Queue Handoff Diagnosis

- [x] **QUEUE-HANDOFF-001** — When an operator-visible project has no queued
  runs, the system SHALL distinguish eligible-but-unseeded candidates, active
  running work, mechanically blocked work, and paused admission; it SHALL NOT
  classify every empty queue as a failure.

- [x] **QUEUE-HANDOFF-002** — When the dashboard reports blocked work, it
  SHALL expose the affected issue and every locally observable blocker source,
  while preserving separate counts for eligible candidates, queued runs, and
  running runs.

- [x] **QUEUE-HANDOFF-003** — When a periodic eligibility sweep creates queued
  work, it SHALL invalidate the dashboard list cache; when diagnosis or a
  source query fails, the dashboard SHALL expose unknown coverage rather than
  claiming that no work exists.
