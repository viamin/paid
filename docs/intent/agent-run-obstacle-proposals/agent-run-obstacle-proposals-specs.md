---
parent: agent-run-obstacle-proposals
prefix: RUN-OBSTACLE
---

# Agent-run obstacle proposal EARS

- [x] **RUN-OBSTACLE-001** — When related failures recur within an account,
  Paid SHALL group them by the existing stable pattern fingerprint with bounded
  sanitized run/revision evidence and SHALL retain the affected goal, scope,
  failure count, and exposure count.

- [x] **RUN-OBSTACLE-002** — When a grouped pattern is diagnosed, Paid SHALL
  use `agent_harness` for semantic classification and SHALL persist an
  inspectable proposal containing obstacle kind, suggested correction, evidence
  pointers, validation plan, and uncertainty; evidence text SHALL be treated
  as data and not as instructions.

- [x] **RUN-OBSTACLE-003** — When the same unresolved proposal is observed,
  Paid SHALL deduplicate on the existing finding identity and target; a
  dismissed proposal SHALL retain its reason and identity. Paid SHALL dismiss
  only a proposed decision after atomically verifying its state.

- [x] **RUN-OBSTACLE-004** — When Paid detects an obstacle, it SHALL NOT apply
  a repair, start an agent run, or enable automatic remediation. Any repair
  SHALL use a separately authorized existing repair path.

- [x] **RUN-OBSTACLE-005** — When an accepted correction is evaluated, Paid
  SHALL record before/after failure and exposure samples from comparable scope;
  it SHALL report insufficient evidence when exposure is not comparable and
  SHALL not claim causality from recurrence counts. It SHALL reevaluate an
  insufficient-evidence outcome only while its bounded after period remains
  open; that outcome is terminal after the period closes.

- [x] **RUN-OBSTACLE-006** — The periodic detection sweep SHALL process a
  bounded page of accounts per job continuation, carrying immutable account-ID
  cursors in its continuation arguments: keyset progress past the last
  processed account and the cycle's captured end, so accounts created during a
  cycle are deferred to the next scheduled cycle. Per-account detection,
  diagnosis budgeting, remediation recording, and notification SHALL remain
  idempotent account units. A failed account SHALL be observable with its
  attempt count, retried once within the cycle, and otherwise deferred to the
  next cycle while remaining accounts continue. The sweep SHALL allow only one
  chain at a time and SHALL report per-account pattern counts, duration, and
  allocations.
  *Code:* `AgentRunPatternDetectorJob#perform`.
  *Test:* `spec/jobs/agent_run_pattern_detector_job_spec.rb`.
