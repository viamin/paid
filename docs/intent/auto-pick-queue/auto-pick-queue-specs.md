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

- [x] **AUTO-PICK-QUEUE-002** — When an issue has an active automatic
  `analyze_issue` provider-exhaustion cooldown, Auto-Pick candidate selection
  SHALL exclude that issue until its persisted next-attempt time. If the
  owner's relevant issue-analysis runner configuration, runner-health state, or
  authentication material changes after the cooldown was recorded, candidate
  selection SHALL treat the cooldown as reset immediately.
  *Tests:* `spec/services/automation/strategies/auto_pick/default_candidate_source_spec.rb`.
  *Code:* `app/services/automation/strategies/auto_pick/default_candidate_source.rb`,
  `app/services/issues/issue_analysis_backoff_reset_context.rb`.
