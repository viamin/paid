# EARS Specs: Queue Handoff Diagnosis

- [x] **QUEUE-HANDOFF-001** — When the Upcoming Queue has no rendered run,
  the system SHALL distinguish queued backend work, active work without a
  waiting backlog, eligible-but-unseeded candidates, deliberate pauses, and
  candidate holds using the existing eligibility and scheduler authorities.
  *Code:* `Dashboard::QueueDiagnosis`.
  *Test:* `spec/services/dashboard/queue_diagnosis_spec.rb`.

- [x] **QUEUE-HANDOFF-002** — When queue-diagnosis data cannot be read, the
  system SHALL report unavailable coverage with a refresh action and SHALL NOT
  infer that no work exists.
  *Code:* `Dashboard::QueueDiagnosis`, `dashboard/_queue_preview.html.erb`.
  *Test:* `spec/services/dashboard/queue_diagnosis_spec.rb`.
