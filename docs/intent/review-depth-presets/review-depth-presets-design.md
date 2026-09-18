---
parent: PAID
prefix: REVIEW-DEPTH
---

# Low-Level Design: Project-Level Review Depth Presets

> Companion to the high-level design (`docs/high-level-design.md`). This
> segment covers the project-level **review depth** preset exposed under
> `review_settings.methods.paid_agent`. It applies only to Paid's own PR
> reviewer — it does not change review-method selection, round caps, wait
> semantics, or GitHub merge policy. See
> `docs/intent/focused-agent-runs/` for the orthogonal focused-run concept
> that scopes which PR problem a run addresses.

## Why a preset, not free-form knobs

Paid's reviewer already enforces a strict evidence and independent-verification
bar — findings require concrete failure scenarios, code paths, or scenarios
backed by file:line references. That bar is constant across presets. What
varies is **how broadly the reviewer investigates beyond the obvious** before
deciding a comment is warranted.

"Strictness" was the original word for this; we replaced it. Strictness
conflates *effort* with the evidence required to publish a comment, and it
suggests that a "less strict" mode can ship a comment without the same
evidence. That is not how the reviewer's contract works: every preset keeps
the same evidence bar. The dimension the operator actually controls is
**investigation depth** — how far beyond the obvious the reviewer looks before
deciding to comment at all.

## The preset vocabulary

`Project::REVIEW_DEPTHS = %w[focused balanced thorough]`. Three named presets,
each defined by the categories of finding it considers alongside the always-on
"obvious correctness and security" floor:

- **focused** — actionable correctness and security findings only. Each finding
  must come with a concrete failure scenario (input, code path, and observed
  vs. expected behavior). Project conventions, performance, maintainability,
  and the deep "what did we just remove" investigation are deliberately out
  of scope. This is the right choice when the operator wants narrow, security-
  shaped review feedback and is willing to run multiple narrow passes for
  other categories.
- **balanced** *(default)* — focused, plus material performance issues
  (algorithmic complexity, N+1, unnecessary allocations, missing caching),
  maintainability concerns (clarity of intent, dead code, error-handling
  shape), and adherence to project conventions the project has already
  declared through conventions, style guides, or prior reviews on this
  PR's neighborhood. This is the default because it covers the categories
  most operators expect a "paid CI" pass to catch without spending search
  budget on every PR.
- **thorough** — balanced, plus deeper investigation of caller compatibility
  (does any other call site in the repo break with this change?), removed
  safeguards (was something protecting an invariant that is now gone?), and
  optional extra knowledge-base or repo-wide search effort where the
  reviewer judges the question warrants it. Thorough is the "no surprises"
  preset for sensitive or expensive-to-undo changes.

Critically:

- **The evidence and independent-verification bar is constant across all
  three presets.** Thorough does not mean "post speculative comments" and
  focused does not mean "suppress severe problems in another category if
  you happen to find them." A thorough review still must not invent
  findings; a focused review that discovers a clear, severe security bug
  while reviewing for security must still report it.
- **The preset only controls Paid's own reviewer.** Copilot, Codex,
  `ci_action`, and `manual` review methods are unaffected — they have their
  own providers and contracts.

## What this segment owns

- A `review_depth` key under
  `Project#review_settings["methods"]["paid_agent"]`, validated against
  `Project::REVIEW_DEPTHS`.
- The default value is `"balanced"` for both new and existing projects, so
  no data backfill is required.
- Surfacing the preset selector in the project automation settings UI
  (edit page) alongside the other Paid PR Code Review Agent controls, and
  the project show page summary row.
- The `effective_review_depth` accessor that returns the resolved preset
  for a project (or `"balanced"` when none is configured).
- A `review_depth_snapshot` column on `AgentRun`, populated at review-run
  creation time from the project's effective preset, so a run's review
  instructions and downstream interpretability stay stable even if the
  project setting changes later.
- Varying the rendered review instructions (`FALLBACK_REVIEW_GOAL_PROMPT`
  in `RunAgentActivity`) so each preset names its investigation scope
  explicitly, without inventing or relaxing the evidence bar.
- Permitting `review_depth` through `ProjectsController#build_review_settings`
  and `ProjectsController#project_params`, so the field round-trips
  through the edit form.

## What this segment does NOT own

- The `wait_for_reviews` top-level toggle, `max_review_rounds`, the per-method
  termination limits, or any external reviewer setting. Review depth is a
  per-preset knob; the existing knobs still mean what they mean.
- Strictness of the comment policy itself — the "comments are reserved
  exclusively for actionable changes" rule and the JSON / evidence bar
  are constant across presets.
- LLM prompt-versioning work; if a future segment wants to vary review
  prompts without the snapshot, it can route through the prompt-versioning
  system. This segment uses the existing goal-prompt machinery and the
  fallback template.
- Auto-pick or auto-continue behavior. The preset affects only the review
  that Paid posts; it does not change when Paid acts.

## Storage location

`review_settings["methods"]["paid_agent"]["review_depth"]` keeps the preset
next to the other paid_agent-only knobs and isolates it from review methods
that don't have a reviewer-controlled depth concept. The default merges in
`Project::DEFAULT_REVIEW_SETTINGS["methods"]["paid_agent"]["review_depth"]`
so callers that only set some keys continue to behave correctly.

## Run-time snapshot

`AgentRun#review_depth_snapshot` is a non-null string column with a
database-level default of `"balanced"`, set when `AgentRun.create!` runs in
`Activities::QueueAgentRunActivity` and `Activities::CreateAgentRunActivity`
for `goal: "review"`. The snapshot is taken from the project's
`effective_review_depth` at creation time and is not mutated afterwards.
This satisfies the acceptance criterion that "a run records its effective
preset and uses a stable value throughout its review."

## UI surface

The project edit form already groups the Paid PR Code Review Agent
controls together (see `app/views/projects/edit.html.erb` around the
paid_agent section). A new labeled `<select>` is added in that group with
the three named options, a short helper line describing the preset, and a
reference back to the broader review-method settings. The project show page
gains a small badge in the review summary that names the active preset.

The form strong-parameters list permits `review_settings.methods.paid_agent.review_depth`,
and `ProjectsController#cast_review_settings` normalizes blank and invalid
values to `nil` so the project's default can take over without persisting
literal `"balanced"` for projects that never set the field.

## Configuration accessors

- `Project#review_depth` — returns the persisted preset under
  `review_settings.methods.paid_agent.review_depth`, or `nil` when not
  configured.
- `Project#effective_review_depth` — returns the merged default
  (`"balanced"` for unconfigured projects, including all existing
  projects).
- `Project::REVIEW_DEPTHS` — `%w[focused balanced thorough]`, the only
  valid values.
- `Project::REVIEW_DEPTH_LABELS` — `{"focused" => "Focused", "balanced" =>
  "Balanced", "thorough" => "Thorough"}` for human display.
- `Project::REVIEW_DEPTH_OPTIONS` — `[ ["Focused", "focused"], ["Balanced",
  "balanced"], ["Thorough", "thorough"] ]` for `form.select`.

The validation rejects any value outside `Project::REVIEW_DEPTHS`, the same
shape `tdd_mode` uses. Invalid values submitted via the API are caught by
the same validation rather than silently coerced, so a malformed payload
fails fast instead of degrading into the default.

## Reviewed-but-out-of-scope

- A "Custom" preset with project-specific category lists: deferred. Three
  presets already cover the dimension operators actually configure. If a
  future segment finds operators asking for per-category toggles, the right
  shape is sub-flags under `methods.paid_agent` (e.g.
  `enable_performance_lookups`) — not a free-form depth integer.
- Per-PR depth overrides via issue labels: deferred. The project-level
  preset is the right gate today because runs are queued and the snapshot
  is taken at queue time; per-PR overrides complicate the snapshot
  contract.