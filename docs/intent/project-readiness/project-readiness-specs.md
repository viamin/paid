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
