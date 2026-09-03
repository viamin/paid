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

- [x] **AUTO-PICK-QUEUE-003** — When a blocking dependency closes, the system
  SHALL reset an open dependent issue from `paid_state=recommend_close` to
  `paid_state=new` only after all of that dependent's still-recorded blocking
  dependencies are resolved, remove the mirrored recommend-close label so
  GitHub labels and `paid_state` stay consistent, and rely on the existing
  paid-state transition recheck path to re-enqueue the issue for Auto-Pick.
  *Tests:* `spec/services/issues/upsert_from_github_spec.rb`,
  `spec/services/automation/strategies/auto_pick/default_candidate_source_spec.rb`.
  *Code:* `app/services/issues/upsert_from_github.rb`, `app/models/issue.rb`.

- [x] **AUTO-PICK-QUEUE-004** — When an issue has `no_code_required_at` set
  (an agent explicitly declared the issue's work complete without a code
  change), Auto-Pick candidate selection SHALL permanently exclude that issue
  from the completed-issue recovery path, regardless of `paid_state`, so a
  no-code-required issue does not loop back into the queue on its own.
  *Tests:* `spec/services/automation/strategies/auto_pick/default_candidate_source_spec.rb`.
  *Code:* `app/services/automation/strategies/auto_pick/default_candidate_source.rb`.

- [x] **AUTO-PICK-QUEUE-005** — When an open issue's `paid_state` is outside
  Auto-Pick's eligible-state set, lifecycle reporting SHALL not classify that
  issue as `:eligible`; lifecycle reporting and Auto-Pick candidate selection
  SHALL derive their eligible-`paid_state` rule from one shared definition,
  including the recoverable `paid_state=completed` path.
  *Tests:* `spec/models/issue_spec.rb`,
  `spec/services/automation/strategies/auto_pick/default_candidate_source_spec.rb`.
  *Code:* `app/models/issue.rb`,
  `app/services/automation/strategies/auto_pick/default_candidate_source.rb`.

- [x] **AUTO-PICK-QUEUE-006** — When Auto-Pick is disabled at the project
  level, a trusted issue-scoped activation label (`paid-automation` or
  `paid-in-full`) MAY still queue work for exactly that issue through the
  explicit label-evaluation path, while every unlabeled issue remains outside
  the queue.
  *Tests:* `spec/services/automation/issue_evaluator_spec.rb`,
  `spec/temporal/activities/detect_labels_activity_spec.rb`.
  *Code:* `app/services/automation/feature_activation.rb`,
  `app/services/automation/label_policy.rb`.
