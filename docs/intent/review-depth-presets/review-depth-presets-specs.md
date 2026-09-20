# EARS Specs: Project-Level Review Depth Presets

> Testable claims for the project-level `review_depth` preset under
> `review_settings.methods.paid_agent` and the `AgentRun#review_depth_snapshot`
> field that records the preset at review-run creation time. Status markers:
> `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r REVIEW-DEPTH-001`).

## Preset definition and validation

- [x] **REVIEW-DEPTH-001** — The system SHALL persist the preset as a string
  under `Project#review_settings["methods"]["paid_agent"]["review_depth"]`,
  restricted to `focused`, `balanced`, or `thorough`. Projects with no
  preset configured (including every pre-existing project) SHALL resolve to
  `"balanced"` through the default merge so existing behavior is preserved
  without a manual migration.
  *Code:* `Project::REVIEW_DEPTHS`, `Project::DEFAULT_REVIEW_SETTINGS`,
  `Project#review_depth`, `Project#effective_review_depth`,
  `Project#review_settings_valid`.
  *Test:* `spec/models/project_spec.rb`, `spec/requests/projects_spec.rb`.

- [x] **REVIEW-DEPTH-002** — `Project#review_settings_valid` SHALL reject any
  `review_settings.methods.paid_agent.review_depth` value outside
  `Project::REVIEW_DEPTHS` (including `nil`-as-blank coercion that lands on
  an unknown value) and the project automation settings UI SHALL render
  `Focused`, `Balanced`, and `Thorough` as the only selectable options so
  users cannot accidentally persist an unsupported preset.
  *Code:* `app/models/project.rb`, `app/views/projects/edit.html.erb`.
  *Test:* `spec/models/project_spec.rb`, `spec/requests/projects_spec.rb`.

## Form round-trip and strong parameters

- [x] **REVIEW-DEPTH-003** — When the project edit form is submitted,
  `ProjectsController#build_review_settings` SHALL permit
  `review_settings.methods.paid_agent.review_depth`, normalize a blank
  submission to `nil` so the default takes over, and reject any submitted
  value outside `Project::REVIEW_DEPTHS` without silently coercing it.
  *Code:* `app/controllers/projects_controller.rb`.
  *Test:* `spec/requests/projects_spec.rb`.

- [x] **REVIEW-DEPTH-004** — When the project edit form persists
  `review_depth`, the field SHALL round-trip through the project record and
  the effective accessor without losing the value, and `Project#reload`
  SHALL return the same preset back. The default value (`"balanced"`)
  SHALL be readable through the same accessor for a project that has never
  set the field.
  *Code:* `Project#review_depth`, `Project#effective_review_depth`.
  *Test:* `spec/models/project_spec.rb`, `spec/requests/projects_spec.rb`.

## Run-time snapshot

- [x] **REVIEW-DEPTH-005** — The system SHALL persist a non-null
  `review_depth_snapshot` string column on `agent_runs` defaulting to
  `"balanced"`, validated against the same three-value vocabulary as the
  project-level preset, so every review run resolves to a known preset and
  legacy runs behave exactly as the project default.
  *Code:* `AgentRun::REVIEW_DEPTHS`, `AgentRun#review_depth_snapshot`,
  `AgentRun` review_depth_snapshot validation, schema migration.
  *Test:* `spec/models/agent_run_spec.rb`.

- [x] **REVIEW-DEPTH-006** — When any creation path queues an `AgentRun`
  capable of `goal: "review"` (`Activities::QueueAgentRunActivity`,
  `Activities::CreateAgentRunActivity`,
  `Projects::AgentRunsController#create_agent_run` including the
  `create_review_runs_and_redirect` flow, or the `Tools::TriggerAgentRun`
  MCP tool), the path SHALL set `review_depth_snapshot` from the project's
  `effective_review_depth` at creation time and SHALL NOT update the
  snapshot thereafter, so a later change to the project preset cannot
  retroactively alter the run's review behavior or its downstream
  interpretability. (The MCP tool snapshots every run it creates; a
  `goal: "review"` call through it is additionally rejected by the
  source-pull-request validation until the tool exposes that parameter,
  so no review run can silently take the DB default.) The manual retry
  and refresh-auth retry paths SHALL carry the original run's
  `review_depth_snapshot` forward so a retry cannot revert review depth
  mid-review-loop.
  *Code:* `Activities::QueueAgentRunActivity`,
  `Activities::CreateAgentRunActivity`,
  `app/controllers/projects/agent_runs_controller.rb`,
  `app/mcp/tools/trigger_agent_run.rb`.
  *Test:* `spec/temporal/activities/queue_agent_run_activity_spec.rb`,
  `spec/temporal/activities/create_agent_run_activity_spec.rb`,
  `spec/requests/agent_runs_spec.rb`,
  `spec/mcp/tools/trigger_agent_run_spec.rb`.

## Rendered review instructions

- [x] **REVIEW-DEPTH-007** — The rendered review-goal prompt — whether
  rendered from the fallback template
  (`RunAgentActivity::FALLBACK_REVIEW_GOAL_PROMPT`), a resolved prompt
  version, or an assigned A/B test variant — SHALL vary its
  investigation scope section by the run's `review_depth_snapshot` —
  Focused limits the named categories to actionable correctness and
  security findings, Balanced adds material performance, maintainability,
  and project-convention categories, Thorough adds caller compatibility,
  removed safeguards, and optional extra search effort — while the
  always-on evidence and JSON / payload rules remain identical across
  presets so Focused cannot publish without the same evidence and
  Thorough cannot publish speculative findings.
  *Code:* `RunAgentActivity::FALLBACK_REVIEW_GOAL_PROMPT`,
  `RunAgentActivity#augment_prompt_for_review_goal`,
  `RunAgentActivity#review_depth_scope_section`.
  *Test:* `spec/temporal/activities/run_agent_activity_spec.rb`,
  `spec/temporal/activities/run_agent_activity_review_depth_spec.rb` (if
  added in the same change).

## Configuration accessor surface

- [x] **REVIEW-DEPTH-008** — `Project` SHALL expose
  `Project::REVIEW_DEPTHS`, `Project::REVIEW_DEPTH_LABELS`, and
  `Project::REVIEW_DEPTH_OPTIONS` so views and configuration code read the
  same vocabulary, and `Project#effective_review_depth` SHALL return the
  merged default for an unconfigured project without writing to the record.
  *Code:* `app/models/project.rb`.
  *Test:* `spec/models/project_spec.rb`.

## Show-page surfacing

- [x] **REVIEW-DEPTH-009** — When PR reviews are enabled and the
  `paid_agent` review method is enabled, the project show page review
  summary SHALL render a badge naming the project's effective
  `review_depth` preset (via `Project::REVIEW_DEPTH_LABELS`), and SHALL NOT
  render the badge when the `paid_agent` method is disabled.
  *Code:* `app/views/projects/show.html.erb`.
  *Test:* `spec/requests/projects_spec.rb`.
