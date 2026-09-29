# EARS Specs: Upstream PR Target

> Testable claims for the open-source / upstream PR target feature on
> `Project` (issue #4076). Status markers: `[x]` implemented, `[ ]` active gap,
> `[D]` deferred. Each ID is a grep target across specs, tests, and code
> (`grep -r PR-TARGET-001`).

## Project model

- [x] **PR-TARGET-001** - A `Project` SHALL expose a `pr_target` column with
  the values `own_repo` (default) and `upstream`, and a nullable
  `upstream_full_name` string column storing the upstream repository as
  `owner/repo`. A row SHALL always carry one valid value; `Project::PR_TARGETS`
  enumerates the vocabulary.
  *Tests:* `spec/models/project_spec.rb` ("PR target / upstream_full_name").
  *Code:* `db/migrate/20260929171254_add_pr_target_and_upstream_full_name_to_projects.rb`,
  `Project::PR_TARGETS`, `Project::DEFAULT_PR_TARGET`.

- [x] **PR-TARGET-002** - The project model SHALL expose `#upstream_pr_target?`
  and `#upstream_disabled?(attribute)` helpers. `upstream_disabled?` SHALL
  return true exactly when `pr_target` is `upstream` and the attribute is in
  `Project::PR_TARGET_UPSTREAM_DISABLED_ATTRIBUTES` — the canonical list of
  fields that cannot operate against a repository Paid does not own or trust.
  *Tests:* `spec/models/project_spec.rb` ("exposes upstream_disabled? based on
  the upstream disabled list"). *Code:* `Project#upstream_pr_target?`,
  `Project#upstream_disabled?`, `Project::PR_TARGET_UPSTREAM_DISABLED_ATTRIBUTES`.

- [x] **PR-TARGET-003** - The fieldset gray-out list SHALL at minimum include
  review_settings, auto_merge_mode, allow_bot_authored_pr_auto_merge,
  auto_release_granularity, owner_reviewer_login, pr_approval_escalation_hours,
  max_draft_review_rounds, max_pr_auto_continue_tokens, auto_add_labels_enabled,
  automation_on_label_enabled, screenshot_settings, and the "Sync Labels to
  GitHub" action. `auto_fix_merge_conflicts` and label-name fields SHALL remain
  enabled.
  *Tests:* `spec/models/project_spec.rb`, `spec/requests/projects_spec.rb`
  ("applies opacity-50 to gated sections when pr_target=upstream").
  *Code:* `Project::PR_TARGET_UPSTREAM_DISABLED_ATTRIBUTES`,
  `app/javascript/controllers/project_settings_form_controller.js`.

- [x] **PR-TARGET-004** - `Project#pr_target_repository` SHALL return the
  project's own full_name when `pr_target=own_repo` and the configured
  `upstream_full_name` (or nil if blank) when `pr_target=upstream`.
  *Tests:* `spec/models/project_spec.rb` ("allows upstream_full_name to be set
  when pr_target=own_repo but ignores it for routing").
  *Code:* `Project#pr_target_repository`.

## Validation

- [x] **PR-TARGET-005** - When `pr_target=upstream`, the system SHALL reject
  the save if `upstream_full_name` is blank, with an error message that
  mentions "required when PR target is upstream".
  *Tests:* `spec/models/project_spec.rb` ("requires upstream_full_name when
  pr_target=upstream"), `spec/requests/projects_spec.rb` ("rejects
  pr_target=upstream when upstream_full_name is missing").
  *Code:* `Project#upstream_pr_target_valid`.

- [x] **PR-TARGET-006** - When `pr_target=upstream`, the system SHALL reject
  a malformed `upstream_full_name` slug (anything that is not `owner/repo`
  matching GitHub's owner + repo slug rules) with an error message that
  mentions "must be a valid owner/repo".
  *Tests:* `spec/models/project_spec.rb` ("rejects a malformed
  upstream_full_name slug"), `spec/requests/projects_spec.rb` ("rejects a
  malformed upstream_full_name slug"). *Code:* `Project#upstream_pr_target_valid`.

- [ ] **PR-TARGET-007** - When `pr_target=upstream`, the system SHOULD
  preflight the GitHub fork network before allowing the save (a literal fork
  and the upstream must share a fork network for cross-repo PRs). When the
  preflight is unavailable, surface as a warning; hard-error when verifiably
  disjoint. Tracked as a follow-up enhancement on top of the upstream PR
  creation issue. *Code:* not yet wired.

- [x] **PR-TARGET-008** - The system SHALL reject `upstream_full_name` equal
  (case-insensitive) to the project's own `full_name` regardless of
  `pr_target`. *Tests:* `spec/models/project_spec.rb` ("rejects
  upstream_full_name matching the project's own repository"),
  `spec/requests/projects_spec.rb` ("rejects upstream_full_name matching the
  project's own repository"). *Code:* `Project#upstream_pr_target_valid`.

## Settings UI

- [x] **PR-TARGET-009** - The settings page SHALL auto-detect the upstream
  repo via `GET /repos/{owner}/{repo}` → `parent.full_name` when available,
  surface a "Detected from fork parent" hint, and fall back to a manual
  entry helper when the project is not a GitHub fork or the GitHub API call
  fails. *Tests:* `spec/services/projects/fork_parent_prefill_spec.rb`,
  `spec/requests/projects_spec.rb` ("renders the manual upstream entry
  hint when no fork parent is detected").
  *Code:* `Projects::ForkParentPrefill`, `app/controllers/projects_controller.rb`
  (`load_upstream_prefill`), `app/views/projects/edit.html.erb`.

- [x] **PR-TARGET-010** - Selecting "Open PRs in the upstream repository"
  SHALL live-update the disabled state of every gated field via the existing
  Stimulus form controller (the JS target list mirrors the model constant).
  Switching back to "own repo" SHALL restore the fields and their prior
  values. *Tests:* `spec/lib/project_settings_form_controller_node_harness_spec.rb`,
  `app/javascript/controllers/project_settings_form_controller.js`.

## Server-side enforcement

- [D] **PR-TARGET-011** - When `pr_target=upstream`, the PR creation flow
  SHALL refuse to mutate, merge, label, or run review automation against the
  upstream repo. This is the enforcement half of the feature, tracked in a
  follow-up issue. *Code:* deferred.

## MCP tooling

- [x] **PR-TARGET-012** - The `update_project_settings` MCP tool SHALL accept
  `pr_target` and `upstream_full_name` so an agent can switch a project to
  upstream mode from chat. The downstream server-side enforcement (see
  PR-TARGET-011) is responsible for refusing any attempt to re-enable the
  gated features while upstream mode is active. *Tests:* covered by the
  shared "slices to permitted attributes" assertions in
  `spec/mcp/tools/update_project_settings_spec.rb`.
  *Code:* `Tools::UpdateProjectSettings::PERMITTED_ATTRIBUTES`.
