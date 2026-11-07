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

- [x] **RUN-OBSTACLE-006** — When the detector sweeps accounts, Paid SHALL
  process a bounded number of accounts per job continuation using a stable
  account keyset cursor and a cycle end captured at cycle start; accounts
  created after the captured end SHALL wait for a later cycle, and duplicate
  overlapping chains SHALL be prevented by bounded enqueue and perform
  concurrency under one concurrency key.

- [x] **RUN-OBSTACLE-007** — When one account's detection fails during a sweep,
  Paid SHALL record that failure with per-account duration and allocation
  metrics and SHALL continue the remaining accounts of the cycle; the failed
  account SHALL be reprocessed by a later cycle, and per-account detection,
  diagnosis budget, remediation recording, and notification SHALL remain
  idempotent across retries and cycles.
