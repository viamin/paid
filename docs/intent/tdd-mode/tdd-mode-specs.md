# EARS Specs: Project TDD Mode (RDR-056)

> Testable claims for the project-level TDD mode configuration and the three
> test-review labels that gate implementation runs. Status markers:
> `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r TDD-MODE-001`).

- [x] **TDD-MODE-001** — A `Project` SHALL persist a `tdd_mode` string column
  restricted to `off`, `non_strict`, or `strict`. Newly created and pre-existing
  projects SHALL default to `"off"` so existing behavior is preserved.
  *Code:* `app/models/project.rb`, `db/migrate/<ts>_add_tdd_mode_to_projects.rb`.
  *Test:* `spec/models/project_spec.rb`.

- [x] **TDD-MODE-002** — `Project#tdd_mode` validation SHALL reject any value
  outside `Project::TDD_MODES` and the project's automation settings UI SHALL
  render `off`, `non_strict`, and `strict` as the only selectable options so
  users cannot accidentally persist an unsupported value.
  *Code:* `app/models/project.rb`, `app/views/projects/edit.html.erb`.
  *Test:* `spec/models/project_spec.rb`.

- [x] **TDD-MODE-003** — `Projects::EnsureStandardLabels` SHALL provision the
  three test-review labels from RDR-056 — `paid-tests-ready-for-review`,
  `paid-tests-approved`, and `paid-test-changes-requested` — alongside the
  other standard labels, creating any that are missing and treating any that
  already exist (with matching color and description) as no-ops so label sync
  remains idempotent across repeated runs.
  *Code:* `app/services/projects/ensure_standard_labels.rb`.
  *Test:* `spec/services/projects/ensure_standard_labels_spec.rb`.

- [x] **TDD-MODE-004** — The three TDD test-review labels SHALL carry stable
  colors and descriptions: `paid-tests-ready-for-review` (yellow/draft-waiting)
  marks draft PRs awaiting test review; `paid-tests-approved` (green) marks
  tests that Paid may implement against; `paid-test-changes-requested`
  (orange/rework) marks tests that the reviewer wants changed before
  implementation begins.
  *Code:* `app/services/projects/ensure_standard_labels.rb`.
  *Test:* `spec/services/projects/ensure_standard_labels_spec.rb`.

- [x] **TDD-MODE-005** — The project show view SHALL display the active TDD mode
  using a human-readable label so operators can verify the persisted value at
  a glance without opening the edit form.
  *Code:* `app/models/project.rb`, `app/views/projects/show.html.erb`.
  *Test:* `spec/models/project_spec.rb`.
