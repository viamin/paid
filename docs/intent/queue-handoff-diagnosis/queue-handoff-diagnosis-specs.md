# EARS Specs: Queue Handoff Diagnosis

- [x] **QUEUE-HANDOFF-001** — When the visible Upcoming Queue is empty and canonical eligibility reports runnable issues, the dashboard SHALL identify the runnable-but-unseeded state, show the count, and name the bounded periodic seeding recovery path; rendering SHALL not invoke recovery or semantic assessment.
  *Code:* `Dashboard::QueueDiagnosis`, `dashboard/_queue_preview.html.erb`.
  *Test:* `spec/requests/dashboard_spec.rb`.

- [x] **QUEUE-HANDOFF-002** — When queue diagnosis cannot read its canonical inputs, the dashboard SHALL report unknown coverage and a refresh action; it SHALL not represent the failure as no waiting work.
  *Code:* `Dashboard::QueueDiagnosis`.
