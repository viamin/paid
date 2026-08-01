# EARS Specs: Auto-Pick Queue

> Testable claims for Auto-Pick queue seeding and draining. Status markers:
> `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code (`grep -r AUTO-PICK-QUEUE-001`).

## Toggle Lifecycle

- [x] **AUTO-PICK-QUEUE-001** — When a project has Auto-Pick disabled, the
  system SHALL cancel that project's queued Auto-Pick agent runs, including
  automatic `enhance_issue` recheck runs, so they are removed from scheduler
  and dashboard upcoming-queue views, while leaving manual and non-queued runs
  unchanged.
  *Tests:* `spec/models/project_spec.rb`, `spec/services/issues/enqueue_eligible_spec.rb`.
  *Code:* `Project#cancel_queued_auto_pick_runs`, `Issues::EnqueueEligible#call`.
