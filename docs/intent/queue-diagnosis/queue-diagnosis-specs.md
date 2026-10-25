# EARS Specs: Queue Diagnosis

- [x] **QUEUE-DIAGNOSIS-001** — When an authorized user's visible Upcoming Queue is empty, the system SHALL distinguish queued runs, capacity-inflight work, and canonical eligible candidates per visible auto-pick project; active work without waiting candidates SHALL be healthy, and candidates with no queued run SHALL be reported as runnable but unseeded.
  *Code:* `app/services/dashboard/queue_diagnosis.rb`, `app/services/dashboard/queue_preview.rb`.
  *Test:* `spec/services/dashboard/queue_diagnosis_spec.rb`.

- [x] **QUEUE-DIAGNOSIS-002** — When the diagnosis finds a deliberate scheduler/quality/policy pause or a human-input hold, it SHALL name the state and supported next action without overriding admission policy; human input SHALL route to the actionable Inbox.
  *Code:* `app/services/dashboard/queue_diagnosis.rb`, `app/views/dashboard/_queue_preview.html.erb`.
  *Test:* `spec/services/dashboard/queue_diagnosis_spec.rb`, `spec/requests/dashboard_spec.rb`.

- [x] **QUEUE-DIAGNOSIS-003** — When diagnosis storage is unavailable, the dashboard SHALL show unknown coverage and a refresh action rather than represent the failure as no work. Dashboard rendering SHALL not invoke an LLM, repository execution, or remote mutation.
  *Code:* `app/services/dashboard/queue_diagnosis.rb`, `app/controllers/dashboard_controller.rb`.
  *Test:* `spec/services/dashboard/queue_diagnosis_spec.rb`.
