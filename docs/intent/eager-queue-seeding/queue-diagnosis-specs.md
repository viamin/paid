# EARS Specs: Queue Diagnosis

> Testable diagnostics layered on the eager queue's canonical candidate and
> scheduler projections. Status markers: `[x]` implemented.

- [x] **EAGER-QUEUE-DIAG-001** — When a visible Upcoming Queue is empty, the
  system SHALL distinguish active work with no waiting backlog, eligible work
  not yet seeded, operator-held work, deliberate policy pauses, and unavailable
  diagnosis using `Dashboard::EligibilityBreakdown` and scheduler queue data;
  it SHALL not infer that no work exists from an empty rendered list.
  *Code:* `Dashboard::QueueDiagnosis`, `DashboardController#queue_preview`.
  *Test:* `spec/services/dashboard/queue_diagnosis_spec.rb`.

- [x] **EAGER-QUEUE-DIAG-002** — Queue diagnosis SHALL expose separately the
  eligible-candidate, queued-run, and active-run counts, a freshness time, and
  a supported next action. If its query fails, it SHALL return `unknown` with
  a refresh action rather than reporting an empty backlog.
  *Code:* `Dashboard::QueueDiagnosis`, `app/views/dashboard/_queue_preview.html.erb`.
  *Test:* `spec/services/dashboard/queue_diagnosis_spec.rb`,
  `spec/requests/dashboard_spec.rb`.
