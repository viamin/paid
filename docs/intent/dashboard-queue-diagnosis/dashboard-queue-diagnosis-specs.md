# EARS Specs: Dashboard Queue Diagnosis

- [x] **DASHBOARD-QUEUE-DIAGNOSIS-001** — When the Upcoming Queue is empty, the system SHALL report independent eligible-candidate, queued-run, and active-run counts and classify the visible state as runnable-unseeded, active work, dependency/decision hold, no waiting work, or unknown coverage without changing scheduler state during rendering.
  *Tests:* `spec/services/dashboard/queue_diagnosis_spec.rb`.
  *Code:* `Dashboard::QueueDiagnosis`, `dashboard/_queue_preview.html.erb`.
