# EARS Specs: Queue Diagnosis

- [x] **AUTO-PICK-QUEUE-014** — When the Upcoming Queue is empty, the system
  SHALL distinguish canonical eligible candidates, scheduler-visible queued
  runs, and active runs. It SHALL report healthy active work with no waiting
  backlog, runnable-but-unseeded work with the existing bounded sweep as the
  recovery action, intentional policy pauses, and canonical holds without
  treating every empty queue as a failure. Rendering SHALL be read-only and
  SHALL not invoke semantic assessment or bypass admission controls.
  *Code:* `app/services/dashboard/eligibility_breakdown.rb`,
  `app/jobs/auto_pick_eligibility_sweep_job.rb`.
  *Test:* `spec/services/dashboard/eligibility_breakdown_spec.rb`.
