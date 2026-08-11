# EARS Specs: Project LID Detection

> Testable claims for downstream-project LID detection. Status markers:
> `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code (`grep -r LID-DETECTION-001`).

## Detection

- [x] **LID-DETECTION-001** — When a repository contains a `## LID` block in
  `AGENTS.md` or `CLAUDE.md`, the system SHALL detect `projects.lid_mode` from
  that block before consulting artifact-only fallbacks.
  *Tests:* `spec/services/projects/detect_lid_mode_spec.rb`.
  *Code:* `app/services/projects/detect_lid_mode.rb`.

- [x] **LID-DETECTION-002** — When a repository has LID-shaped artifacts but no
  explicit `## LID` block, the system SHALL infer Full mode from the artifact
  presence and record the source paths in detection metadata.
  *Tests:* `spec/services/projects/detect_lid_mode_spec.rb`.
  *Code:* `app/services/projects/detect_lid_mode.rb`.

- [x] **LID-DETECTION-003** — When a `## LID` block is present but `- Mode:` is
  missing or malformed, the system SHALL default to Full mode and record a
  one-line warning in detection metadata.
  *Tests:* `spec/services/projects/detect_lid_mode_spec.rb`.
  *Code:* `app/services/projects/detect_lid_mode.rb`.

- [x] **LID-DETECTION-004** — When a project declares Scoped mode but omits a
  `## LID Scope` section, the system SHALL keep Scoped mode, record a warning,
  and treat future scope checks as in-scope by default until scope is declared.
  *Tests:* `spec/services/projects/detect_lid_mode_spec.rb`.
  *Code:* `app/services/projects/detect_lid_mode.rb`.

- [x] **LID-DETECTION-005** — When neither LID directives nor LID-shaped
  artifacts are present, the system SHALL clear `projects.lid_mode` and persist
  detection metadata showing no configured LID sources.
  *Tests:* `spec/services/projects/detect_lid_mode_spec.rb`.
  *Code:* `app/services/projects/detect_lid_mode.rb`.

- [x] **LID-DETECTION-009** — When a `## LID` block declares an LID mode but
  the standard design docs (`docs/high-level-design.md`, `docs/intent/`) are
  absent from the repository, the system SHALL record a warning in detection
  metadata so downstream contract injection does not reference nonexistent
  docs and agents do not waste tokens searching for them.
  *Tests:* `spec/services/projects/detect_lid_mode_spec.rb`.
  *Code:* `app/services/projects/detect_lid_mode.rb`.

## Lifecycle and override

- [x] **LID-DETECTION-006** — When project conventions are collected during repo
  import or normal collector sync, the system SHALL refresh the project's LID
  detection from the checked-out repository in the same scan path.
  *Tests:* `spec/services/project_conventions/detect_for_import_spec.rb`,
  `spec/services/knowledge/collectors/project_conventions_collector_spec.rb`.
  *Code:* `app/services/knowledge/collectors/project_conventions_collector.rb`.

- [x] **LID-DETECTION-007** — When a project owner updates project settings, the
  system SHALL allow forcing `projects.lid_mode` on or off directly, and SHALL
  support an explicit re-detect action that replaces the effective mode with the
  repo-derived result.
  *Tests:* `spec/requests/projects_spec.rb`.
  *Code:* `app/controllers/projects_controller.rb`, `app/views/projects/edit.html.erb`.

- [x] **LID-DETECTION-008** — When a project owner has manually forced
  `projects.lid_mode`, the system SHALL NOT overwrite it during background
  detection (repo import or collector sync); the override SHALL persist until
  the owner explicitly requests re-detection.
  *Tests:* `spec/services/projects/detect_lid_mode_spec.rb`, `spec/requests/projects_spec.rb`.
  *Code:* `app/services/projects/detect_lid_mode.rb`, `app/controllers/projects_controller.rb`.
