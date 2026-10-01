# LLD: Upstream-Mode Gating

> parent: docs/high-level-design.md
> prefix: UPSTREAM-GATE

# ## Problem
#
# #4076 introduced "upstream mode" — the ability for a Paid-managed project
# to open pull requests against an *upstream* repository (an external
# project Paid does not control) instead of the project's own fork. The
# mode exists so a Paid deployment can land contributions on an external
# repo, but Paid has no trusted access to that upstream repository: it
# cannot grant it as a collaborator, post review comments on third-party
# PRs, or push to it as an owner. Any automation that touches the upstream
# repository or PRs opened in it therefore acts outside the trust boundary
# the rest of the system assumes.
#
# #4078 closes that gap by enforcing upstream-mode restrictions
# *server-side*: the model is the authority for what upstream mode disables,
# every gated feature consults the concern instead of reading `pr_target`
# directly, and the chat path cannot bypass the form's disabled inputs.
#
# ## Design
#
# ### Authority and disable set
#
# `Project::UpstreamAutomation` is the ONE place that decides what upstream
# mode disables. It exposes:
#
# - `upstream_pr_target?` — the mode predicate (`pr_target == "upstream"`
#   with `upstream_full_name` configured).
# - `DISABLED_FEATURES` — the canonical disable set:
#   - `pr_reviews`
#   - `auto_merge`
#   - `auto_release`
#   - `auto_scan_prs`
#   - `pr_labeling`
#   - `owner_review_requests`
#   - `draft_review_rounds`
#   - `screenshots`
#   - `upstream_issue_labeling`
#   - `upstream_issue_comments`
# - `upstream_automation_allowed?(feature)` — the capability check every
#   gated feature must consult.
# - `upstream_feature_enabled?(feature)` — capability check with the
#   `upstream_mode_skipped` observability hook.
# - `log_upstream_mode_skipped(feature, **metadata)` — shared log, memoized
#   per feature per project instance, so a run that consults a predicate
#   repeatedly still logs exactly once.
#
# Nothing outside the concern reads `pr_target` directly to decide whether
# a feature is allowed in upstream mode; this keeps the disable set from
# drifting as new code paths are added.
#
# ### Save-time hard gating
#
# `upstream_mode_automation_settings_valid` is a save-time validation:
# while `pr_target` is `"upstream"`, the project cannot store an enabled
# value for any gated setting (`auto_merge_mode`, `allow_bot_authored_pr_auto_merge`,
# `auto_release_granularity`, `review_settings`, `auto_add_labels_enabled`,
# `inherit_priority_labels`, `owner_reviewer_login`,
# `screenshot_settings`). The UI grays the settings out (#4076); the model
# is the authority, so the form cannot be circumvented by a chat-driven
# `update_project_settings` call or by a manual SQL update.
#
# ### Chat path guard
#
# `Tools::UpdateProjectSettings` slices inbound settings to
# `PERMITTED_ATTRIBUTES` and then calls
# `project.upstream_gated_setting_violations(attrs)`. Any gated setting
# whose value would enable a disabled feature raises `ArgumentError`
# with the offending keys listed, so the chat path cannot bypass the
# form's disabled inputs.
#
# ### Controller-level enforcement
#
# `ProjectsController#toggle_auto_merge` short-circuits with a redirect +
# alert when the project targets PRs upstream. Auto-merge is not just
# inert at runtime — its toggle cannot cycle it on — because the model
# validation would reject the save anyway.
#
# ### Issue-side automation
#
# Issue polling, auto-pick, and enhancement remain available. Writes to
# upstream issues (labels and comments) and Sync Labels are gated. Conflict
# fixes remain available only after verifying that the PR head belongs to the
# fork; a fix targeting an upstream-owned base branch is rejected before
# checkout and push. `ScanPaidPrsActivity` retains a separate conflict-only
# path for saved upstream PR records: it reads mergeability from the upstream
# repository and can queue a fix on the fork-owned head, but does not run CI,
# review, merge, label, or lifecycle automation.
#
# ## Code
#
# `app/models/concerns/project/upstream_automation.rb`,
# `app/models/project.rb`,
# `app/mcp/tools/update_project_settings.rb`,
# `app/controllers/projects_controller.rb`,
# `app/jobs/recover_missing_pull_request_labels_job.rb`,
# `app/services/automation/feature_activation.rb`,
# `app/temporal/activities/capture_screenshots_activity.rb`,
# `app/temporal/activities/create_aggregated_pull_request_activity.rb`,
# `app/temporal/activities/create_pull_request_activity.rb`,
# `app/temporal/activities/merge_pull_request_activity.rb`,
# `app/temporal/activities/request_review_activity.rb`,
# `app/temporal/activities/scan_paid_prs_activity.rb`,
# `db/migrate/20260929183232_add_pr_target_to_projects.rb`.
# Tests: `spec/models/concerns/project/upstream_automation_spec.rb`,
# `spec/services/automation/feature_activation_spec.rb`,
# `spec/temporal/activities/scan_paid_prs_activity_spec.rb`,
# `spec/mcp/tools/update_project_settings_spec.rb`,
# `spec/requests/projects_spec.rb`.
