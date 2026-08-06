# EARS Specs: Quality Feedback Loops

> Testable claims for the current shipped quality/backpressure mechanisms that
> replaced the draft shapes from RDR-013. Status markers: `[x]` implemented ·
> `[ ]` active gap · `[D]` deferred. Each ID is a grep target across specs,
> tests, and code (`grep -r QUALITY-LOOPS-001`).

- [x] **QUALITY-LOOPS-001** — The system SHALL resolve effective managed-project
  pre-commit requirements by merging account-, user-, and project-scoped
  records by name with precedence `project > user > account`, and a disabled
  override SHALL suppress an inherited requirement with the same name.
  *Code:* `app/models/pre_commit_requirement.rb`.
  *Test:* `spec/models/pre_commit_requirement_spec.rb`.

- [x] **QUALITY-LOOPS-002** — When pre-commit requirements are evaluated for an
  agent run, the evaluator SHALL execute the effective requirements for the run
  user/owner in the container, SHALL treat warn-mode failures as non-blocking,
  and SHALL treat block/auto-fix failures as blocking run feedback.
  *Code:* `app/services/pre_commit_requirements/evaluate.rb`.
  *Test:* `spec/services/pre_commit_requirements/evaluate_spec.rb`.

- [x] **QUALITY-LOOPS-003** — When a resolved requirement is a mutation test,
  the quality loop SHALL route the command through the canonical results
  directory and SHALL surface surviving mutations as structured quality
  feedback instead of pass-through command output only.
  *Code:* `app/services/pre_commit_requirements/evaluate.rb`,
  `app/services/containers/quality_hooks.rb`.
  *Test:* `spec/services/pre_commit_requirements/evaluate_spec.rb`,
  `spec/services/containers/quality_hooks_spec.rb`.

- [x] **QUALITY-LOOPS-004** — When a DB-dependent language project (Ruby/Rails or
  Elixir/Phoenix) has no running database service container, the installed
  container quality hooks SHALL replace that language's test and mutation
  commands with no-ops so commits are not trapped behind infrastructure-dependent
  hook failures. Non-DB languages keep their test hooks; in a polyglot repo only
  the DB-dependent languages are gated.
  *Code:* `app/services/containers/quality_hooks.rb`.
  *Test:* `spec/services/containers/quality_hooks_spec.rb`.

- [x] **QUALITY-LOOPS-005** — The quality-gate activity SHALL block automatic
  work when the rolling recent quality metrics breach the configured gate, but
  SHALL bypass manual runs and priority-labeled issue/PR work, and SHALL record
  the gate result into workflow state when a workflow ID is supplied.
  *Code:* `app/temporal/activities/check_quality_gate_activity.rb`.
  *Test:* `spec/temporal/activities/check_quality_gate_activity_spec.rb`.

- [x] **QUALITY-LOOPS-006** — The review-bot trigger parser SHALL preserve the
  ordered reviewer chain from `request_logids` when present and SHALL fall back
  to the legacy single `request_login` field when the array is absent or empty.
  *Code:* `app/services/automation/review_bot_trigger.rb`.
  *Test:* `spec/services/automation/review_bot_trigger_spec.rb`.
