# EARS Specs: Queue Delivery Diagnosis

- [x] **QUEUE-DELIVERY-DIAGNOSIS-001** — When Upcoming Queue is rendered, the
  system SHALL use the canonical eligibility breakdown and persisted scheduler
  data to distinguish candidate work, queued work, and active work, and SHALL
  classify an empty projection as active-without-backlog, runnable-unseeded,
  configured-hold, policy/resource-pause, rendered-stale, or unknown coverage.
  A query failure SHALL produce unknown coverage rather than a no-work claim.

- [x] **QUEUE-DELIVERY-DIAGNOSIS-002** — When runnable candidates are present
  without queued or active work, the diagnosis SHALL expose inspectable issue
  provenance and the supported recovery path; dashboard rendering SHALL NOT
  enqueue work, invoke an LLM, execute repository code, or mutate remote state.

- [x] **QUEUE-DELIVERY-DIAGNOSIS-003** — When scheduler data contains queued
  work but the rendered queue projection is empty, the system SHALL state that
  the projection needs refresh rather than reporting no queued work.
