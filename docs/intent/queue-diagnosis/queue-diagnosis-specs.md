# EARS Specs: Queue Diagnosis

- [x] **QUEUE-DIAGNOSIS-001** — When the Upcoming Queue is evaluated, the
  system SHALL distinguish queued runs, active work without waiting backlog,
  canonically eligible but unseeded issues, dependency/decision holds, explicit
  resource/policy pauses, no waiting work, and unavailable diagnosis without
  treating an empty rendered queue as proof that no work exists.
  *Code:* `app/services/dashboard/queue_diagnosis.rb`.
  *Test:* `spec/services/dashboard/queue_diagnosis_spec.rb`.

- [x] **QUEUE-DIAGNOSIS-002** — When a visible open issue is blocked by local
  dependencies, the diagnosis SHALL expose the dependent issue and every
  currently blocking local issue, without performing a remote call or mutation.
  *Code:* `app/services/dashboard/queue_diagnosis.rb`.
  *Test:* `spec/services/dashboard/queue_diagnosis_spec.rb`.

- [x] **QUEUE-DIAGNOSIS-003** — When diagnosis cannot read its canonical
  eligibility or scheduler data, the dashboard SHALL report unknown coverage
  and a refresh action rather than reporting no work.
  *Code:* `app/services/dashboard/queue_diagnosis.rb`.
  *Test:* `spec/services/dashboard/queue_diagnosis_spec.rb`.
