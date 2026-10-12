---
parent: project-readiness
prefix: PROJECT-READINESS
---

# EARS Specs: Project readiness

- [x] **PROJECT-READINESS-001** — When a caller supplies a project and an
  available repository checkout, the system SHALL return a readiness result
  with an evaluated-at timestamp and zero or more gaps, where every gap has
  `kind`, `description`, and structural `evidence`, without writing state,
  acquiring a repository, or requesting AI judgment.
  *Code:* `Projects::Readiness`, `Projects::Readiness::Evaluate`.
  *Test:* `spec/services/projects/readiness_spec.rb`.

- [x] **PROJECT-READINESS-002** — When a project's `tdd_mode` is `strict` or
  `non_strict`, the system SHALL report a `missing_ci` gap unless the checkout
  contains `.github/workflows/`, `.circleci/config.yml`, or `.gitlab-ci.yml`;
  SHALL report a `missing_test_directory` gap unless the applicable detector's
  test directory exists; and SHALL report a `missing_test_command` gap unless
  the applicable detector identifies a runnable command.
  *Code:* `Projects::Readiness::Rules::Tdd`.
  *Test:* `spec/services/projects/readiness_spec.rb`.

- [x] **PROJECT-READINESS-003** — When `tdd_mode` is `off`, the system SHALL
  add no TDD-specific readiness gaps, while allowing independent future rules
  to add their own gaps.
  *Code:* `Projects::Readiness::Rules::Tdd`.
  *Test:* `spec/services/projects/readiness_spec.rb`.

- [x] **PROJECT-READINESS-004** — When a detector is added for an ecosystem,
  the system SHALL select it before the language-command fallback when it is
  applicable. For Godot/GDScript, the detector SHALL use `test`/`tests` as
  test-directory evidence and `addons/gdUnit4` as test-command evidence; the
  Forager-iOS fixture containing only `AGENTS.md`, `README.md`, and `docs/`
  SHALL therefore report all three strict-TDD gaps.
  *Code:* `Projects::Readiness::Detector`,
  `Projects::Readiness::Detectors`,
  `Projects::Readiness::Detectors::Godot`.
  *Test:* `spec/services/projects/readiness_spec.rb`.

- [x] **PROJECT-READINESS-005** — When an enabled TDD project's persisted
  readiness snapshot has one or more gaps, the system SHALL surface exactly one
  project-backed `project_setup_pending` Inbox entry to authorized operators,
  including every stored gap's description and evidence; it SHALL not require
  `auto_pick_enabled`, and a satisfied snapshot SHALL not appear.
  *Code:* `Inbox::Queue`, `Inbox::Count`, `Inbox::Availability`.
  *Test:* `spec/services/inbox/queue_spec.rb`, `spec/services/inbox/count_spec.rb`,
  `spec/services/inbox/availability_spec.rb`.

- [x] **PROJECT-READINESS-006** — When a readiness evaluation records a gap
  set different from the project's prior snapshot, the system SHALL persist the
  result and invalidate the Inbox cache. It SHALL queue re-evaluation after a
  TDD-mode setting change and after a completed run with a result commit, but
  SHALL not evaluate during Inbox polling.
  *Code:* `Projects::Readiness::Record`, `EvaluateProjectReadinessJob`,
  `Project`, `AgentRun`.
  *Test:* `spec/services/projects/readiness/record_spec.rb`,
  `spec/models/project_spec.rb`, `spec/models/agent_run_spec.rb`.
