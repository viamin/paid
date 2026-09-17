# EARS Specs: Feature Approval — Operating Mode & Onboarding

> Testable claims for the human-led feature operating mode from
> [RDR-066](../../rdrs/RDR-066-feature-intent-approval-lifecycle.md)
> (issue #3872: named profile and onboarding posture). Status markers:
> `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r FEATURE-APPROVAL-001`).

- [x] **FEATURE-APPROVAL-001** — When the human-led feature operating mode
  ships, the `operating_mode` column SHALL default to `standard` and reject
  unknown values, so no existing project is silently enrolled and new
  projects start unenrolled unless the mode is deliberately chosen.

- [x] **FEATURE-APPROVAL-002** — When the `human_led_feature_factory`
  configuration profile is applied, the project SHALL enter the human-led
  feature operating mode with `non_strict` TDD as the suggested
  test-review posture, and `auto_merge_mode` SHALL remain `off` unless the
  operator explicitly selects otherwise.

- [x] **FEATURE-APPROVAL-003** — When an operator adopts the profile with
  explicit auto-merge or TDD selections, the system SHALL apply those
  selections instead of the suggested defaults, so auto-merge and strict
  human test review remain independent project choices.

- [x] **FEATURE-APPROVAL-004** — When a new account reaches the
  configure-defaults onboarding step with a first project, onboarding SHALL
  propose the `human_led_feature_factory` posture with a reviewable
  settings plan and SHALL apply it only after the user accepts the
  proposal.

- [x] **FEATURE-APPROVAL-005** — When a project leaves the
  `human_led_feature_factory` operating mode, the system SHALL NOT release,
  enqueue, or otherwise mutate issue or run state; disabling the mode is a
  settings-only change and any held work stays held until explicitly
  migrated.
