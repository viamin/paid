---
parent: PAID
prefix: STYLE-GUIDE-EVOLUTION
---

# Style Guide Evolution Design

## Context

RDR-035 proposed a self-improving style guide pipeline: run outcomes tell Paid
which style guide content produces better quality scores, and the system
mutates and A/B tests underperforming guides automatically rather than
requiring a human to hand-tune them. The
[2026-08-04 RDR audit](../../rdrs/audit-report-2026-08-04-rdr-035.md) confirmed
the full pipeline shipped: immutable versioned content, style-guide-specific
A/B tests, per-run exposure tracking, a Temporal-driven evolution workflow, and
quality-score attribution back to the assigned variant. This segment backfills
LID coverage for that shipped pipeline; it does not introduce new behavior.

This segment covers the evolution and A/B-testing pipeline for style guides
specifically. Compression, extraction, and code-sample collection for style
guides are separate concerns covered elsewhere; static prompt injection budget
mechanics that are not evolution-specific stay in `StyleGuides::InjectIntoPrompt`
and are only described here to the extent they participate in exposure
tracking and A/B assignment.

## Goals

- Store style guide content as immutable, lineage-tracked versions so an
  evolved variant can be compared against — and later replace — a known parent
  without losing history.
- Record which style guide version an agent run actually saw, and which
  A/B-test arm (if any) it was assigned to, so quality scores can be
  attributed to specific content.
- Periodically sample recent runs per style guide, detect versions whose
  average quality score has fallen below a threshold, and treat them as
  evolution candidates.
- Generate full-guide mutation candidates through an LLM call, bounded in
  count and size, with sensitive content redacted before it leaves the
  process.
- Run mutated variants against the current version in a statistically
  gated A/B test, and promote the winning version back onto the mutable
  `style_guides` row when a winner is found with sufficient confidence.

## Design

### Versioned, immutable content (`StyleGuideVersion`)

- `StyleGuideVersion` (`app/models/style_guide_version.rb`) stores `raw_content`
  plus `version`, `style_guide_id`, `created_by`, `created_by_user_id`,
  `parent_version_id`, and `change_notes`.
- `IMMUTABLE_ATTRIBUTES` blocks updates to content-identity fields after
  creation via the `immutable_content_after_creation` validation — once a
  version is persisted, its content cannot be edited, only superseded by a new
  version with `parent_version` pointing back at it.
- `parent_version_belongs_to_style_guide` keeps lineage within a single style
  guide; child versions cannot be reparented across guides.
- `content_for_prompt` returns compressed content when available, otherwise
  truncates `raw_content` to a per-project or default byte budget
  (`StyleGuide::DEFAULT_MAX_RAW_PROMPT_BYTES`) so injection never exceeds the
  prompt budget.

### Exposure recording and A/B assignment during prompt injection

- `StyleGuides::InjectIntoPrompt` (`app/services/style_guides/inject_into_prompt.rb`)
  resolves the applicable style guides for a project, selects sections within
  a total byte budget, and — when an `agent_run` is present — records one
  `StyleGuideRunExposure` per injected guide via `record_exposures!`.
- For each guide, `resolve_guide_version` first looks for an existing
  `StyleGuideAbTestAssignment` for the run (`existing_assignment_for`); if none
  exists and a `StyleGuideAbTest` is `running` for the account/guide, it
  enrolls the run through `StyleGuideAbTests::Assign` (`assign_running_ab_test_for`).
  If no test applies, it falls back to the guide's `current_version`.
- `StyleGuideRunExposure` (`app/models/style_guide_run_exposure.rb`) records
  `guide_name`, `source_scope` (`project`/`account`/`global`), `position`,
  `injected_via`, `injected_content`, the resolved `style_guide_version`, and
  the linked `style_guide_ab_test_assignment` when one applies. A validation
  (`assignment_matches_version`) keeps the recorded version consistent with
  the assignment's variant version.
- `StyleGuideAbTests::Assign` (`app/services/style_guide_ab_tests/assign.rb`)
  is idempotent per `(style_guide_ab_test, agent_run)` and uses inverse-count
  weighting (`select_variant`) so under-sampled variants are more likely to be
  picked, converging toward an even split over time; a unique-constraint race
  falls back to re-reading the existing assignment.

### Evolution candidate sampling

- `StyleGuideEvolution::SampleRuns` (`app/services/style_guide_evolution/sample_runs.rb`)
  joins `StyleGuideRunExposure` to automated `QualityMetric` rows for a given
  style guide over a trailing window (`DEFAULT_DAYS` = 14, `DEFAULT_SAMPLE_SIZE`
  = 50), groups by exposed version, and computes per-version run counts and
  average composite scores.
- `identify_candidates` flags a version as an evolution candidate only when it
  has at least `MIN_RUNS_FOR_EVALUATION` (5) samples and its average score is
  below `QUALITY_THRESHOLD` (0.7) — this keeps low-sample noise from
  triggering unnecessary mutation.
- `Activities::SampleStyleGuideRunsActivity` wraps this service as a Temporal
  activity input/output boundary.

### Mutation generation

- `StyleGuideEvolution::Mutate` (`app/services/style_guide_evolution/mutate.rb`)
  calls `AgentHarness.send_message` (text-mode, `tools: :none`) with the
  current guide content — redacted through `Knowledge::Redaction::Redactor`
  first — and the sampled performance summary, asking for a bounded number
  (`MIN_MUTATION_COUNT`..`MAX_MUTATION_COUNT`, default 3) of full-guide
  replacement variants tagged with a strategy drawn from
  `PromptEvolution::Mutate::STRATEGIES`.
- Generated content over `MAX_GENERATED_TEMPLATE_LENGTH` is dropped, and any
  `AgentHarness::Error` or unparseable response yields an empty mutation list
  rather than raising — mutation generation degrades to "no evolution this
  cycle," not a failure.

### Variant persistence and evolution orchestration

- `StyleGuideEvolution::CreateVariants` (`app/services/style_guide_evolution/create_variants.rb`)
  persists each accepted mutation as a new `StyleGuideVersion` with
  `parent_version` set to the guide's current version, `created_by:
  "evolution"`, `review_status: "approved"`, and an idempotency key derived
  from the workflow's idempotency key plus mutation content/strategy so a
  retried Temporal activity does not duplicate versions.
- `Workflows::StyleGuideEvolutionWorkflow` (`app/temporal/workflows/style_guide_evolution_workflow.rb`)
  chains sample → mutate → create variants → create A/B test as Temporal
  activities, short-circuiting to a `no_candidates`/`no_mutations`/
  `no_variants_created` result at each stage when the prior stage produced
  nothing.
- `StyleGuideEvolutionJob` (`app/jobs/style_guide_evolution_job.rb`) is the
  scheduling entry point: it selects active, non-global style guides that
  have a current version, have received exposures within the sample window,
  and are not already enrolled in a running A/B test for their account, then
  starts one `StyleGuideEvolutionWorkflow` per eligible guide keyed by
  `style-guide-evolution-<project_or_account>-<style_guide_id>-<date>` for
  idempotent daily scheduling.
- `StyleGuideAbTests::Create` (`app/services/style_guide_ab_tests/create.rb`)
  builds the `StyleGuideAbTest` plus its control and evolved variants in one
  transaction, enforcing a single running test per account
  (`idx_on_profile...` / unique index) and rejecting duplicate or missing
  variant version ids.

### Quality attribution, analysis, and promotion

- `StyleGuideAbTests::RecordResult` (`app/services/style_guide_ab_tests/record_result.rb`)
  records a run's quality score onto its assignment exactly once by default
  (`update_existing: false` short-circuits repeats), updates the variant's
  running `sample_count`/`total_quality_score`/`avg_quality_score` under a
  row lock, and triggers `check_auto_completion` once sampling thresholds are
  hit or an `ANALYSIS_INTERVAL` boundary is crossed.
- `StyleGuideAbTests::Analyze` (`app/services/style_guide_ab_tests/analyze.rb`)
  runs a Welch's t-test (`AbTests::Statistics.welch_t_test`) between the
  control arm and each variant, and classifies the test outcome as
  `winner_found` (a variant significantly beats control), `control_wins` (every
  significant difference favors control), or `no_significant_difference`.
  `StyleGuideAbTest#cached_or_compute_analysis` memoizes the result keyed by a
  bucketed sample-count signature so repeated calls between new samples reuse
  the cached verdict.
- On `winner_found`, `RecordResult#check_auto_completion` completes the test
  and calls `StyleGuideAbTests::PromoteWinner`
  (`app/services/style_guide_ab_tests/promote_winner.rb`), which copies the
  winning version's `raw_content` onto the mutable `style_guides` row,
  clears cached compression, sets `current_version_id`, and enqueues
  recompression via `StyleGuides::EnqueueCompression`. On `control_wins`, the
  test is simply completed with no promotion.

## Trace Notes

- The evolution pipeline never mutates `style_guides.raw_content` directly
  except through `PromoteWinner` — all evolved content lives in
  `StyleGuideVersion` rows until a winner is confirmed. This is what keeps a
  losing A/B test from corrupting the guide agents are currently using.
- `StyleGuideEvolutionJob` deliberately excludes global style guides
  (`account_id` and `project_id` both nil) from automatic evolution — only
  account- and project-scoped guides are eligible, since global guides are
  shared across tenants and quality attribution would be cross-tenant noise.
- The RDR's implementation plan named separate `StyleGuides::RecordRunExposures`,
  `StyleGuides::BuildInjectedGuideSet`, and `StyleGuides::RenderContentForPrompt`
  services; the shipped implementation folds this behavior into
  `StyleGuides::InjectIntoPrompt` instead. This is a packaging difference, not
  a scope gap — see the RDR-035 audit report for the reconciliation.
