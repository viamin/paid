# EARS Specs: Queue Handoff Diagnosis

- [x] **QUEUE-HANDOFF-001** — When the Upcoming Queue has no visible queued
  work, the dashboard SHALL distinguish active work, eligible-but-unseeded
  work, deliberately held work, and no visible backlog using the canonical
  eligibility scope and scheduler rows; eligible counts and queued/in-flight
  counts SHALL remain separate.

- [x] **QUEUE-HANDOFF-002** — When diagnosis cannot read eligibility or
  scheduler data, the dashboard SHALL report unknown coverage with a refresh
  action and SHALL NOT claim that no work exists.

- [x] **QUEUE-HANDOFF-003** — When an eligible issue lacks a queued or
  in-flight automatic run, the bounded eligibility sweep SHALL recover it only
  through the existing idempotent seeding path and SHALL invalidate dashboard
  list content after creating work.
