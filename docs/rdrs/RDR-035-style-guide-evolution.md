# RDR-035: Style Guide Evolution

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-05-24
- **Status**: Implemented
- **Type**: Architecture
- **Priority**: High
- **Related Issues**: #2254, #2249
- **Related RDRs**: [RDR-009](RDR-009-prompt-evolution.md) (Prompt Evolution)
- **Related Tests**: `spec/services/style_guides/inject_into_prompt_spec.rb`, `spec/services/style_guide_evolution/mutate_spec.rb`, `spec/services/style_guide_ab_tests/{analyze,record_result,promote_winner}_spec.rb`, `spec/jobs/style_guide_evolution_job_spec.rb`, `spec/temporal/activities/sample_style_guide_runs_activity_spec.rb`

## Implementation Status

Implemented and audited on Tuesday, August 4, 2026. Paid now ships the full style-guide evolution pipeline:

- Immutable style-guide versions and current-version pointers via `db/migrate/20260709225313_create_style_guide_evolution_pipeline.rb` and `app/models/style_guide_version.rb`
- Style-guide-specific A/B tests, assignments, and result attribution via `app/models/style_guide_ab_test*.rb` and `app/services/style_guide_ab_tests/`
- Runtime exposure recording and assigned-arm injection in `app/services/style_guides/inject_into_prompt.rb`
- Weekly discovery plus Temporal orchestration via `app/jobs/style_guide_evolution_job.rb` and `app/temporal/workflows/style_guide_evolution_workflow.rb`

The close-out audit is recorded in [audit-report-2026-08-04-rdr-035.md](audit-report-2026-08-04-rdr-035.md).

## Problem Statement

When this RDR was drafted, the prompt evolution pipeline (`PromptEvolution::Mutate`, `PromptEvolutionWorkflow`) only mutated `Prompt` / `PromptVersion` records. `StyleGuide` records were versioned via Logidze for audit purposes but were never evolved. PR #2249 seeded an initial set of global style guides on the expectation that they would later be improved over time by the evolution code, but there was no mechanism to do so.

Four hard design questions must be resolved before implementation:

1. **Variant structure** — How do we create immutable, versioned snapshots of style guide content for A/B comparison?
2. **Mutation prompt** — How does LLM-driven mutation of style guide `raw_content` work, and what guardrails prevent the mutation from degrading the guide?
3. **Sampling story** — Multiple style guides are injected per prompt run. How do we attribute agent run quality outcomes back to a specific style guide variant?
4. **Control vs variant assignment** — How do we structure A/B comparison when multiple guides are in play simultaneously?

## Context

### Background

**StyleGuide model** (`app/models/style_guide.rb`):

- Three scope levels: global (`account_id: nil, project_id: nil`), account (`account_id: present, project_id: nil`), project (`project_id: present`)
- `raw_content` is the canonical content (authored by users or LLM-extracted via `StyleGuides::Extract`)
- `compressed_content` is an LLM-compressed token-efficient variant used for prompt injection (`StyleGuides::Compress`)
- Logidze tracks every update to `log_data` jsonb for audit history, but logidze records every change (including name, active flag, language toggles) and does not provide semantic version snapshots
- **At draft time no `style_guide_versions` table existed** — there was no immutable version store, no parent lineage, and no usage statistics per version

**Style guide injection** happens at prompt-build time via `StyleGuides::InjectIntoPrompt`:

- Called by `BuildForIssue` and `BuildForPr`
- Resolves applicable guides via `StyleGuide.resolve_for(project)` (specificity inheritance: project > account > global)
- Injects formatted guides into the prompt within a byte budget

At draft time, the main issue-run path had an important exception: `CreateAgentRunActivity` could render and persist an issue `custom_prompt` up front, then apply `ProjectConventions::InjectIntoPrompt` directly, bypassing `StyleGuides::InjectIntoPrompt`. The shipped implementation closes that gap for PromptVersion-backed issue runs by calling `maybe_inject_style_guides!` immediately after creating the `AgentRun` whenever a caller did not provide a custom prompt. Caller-supplied custom prompts still intentionally skip style-guide injection, so any future design that needs assignment or exposure tracking for fully custom prompts must cover that path explicitly.

`ChatSessions::BuildSystemPrompt` also renders style guide content, but it currently builds that section inline rather than calling `StyleGuides::InjectIntoPrompt`. Because the design below is built around `AgentRun`-backed assignment, exposure recording, and later quality-score attribution, chat-session prompt rendering is explicitly out of scope for the initial implementation.

**PromptEvolution pipeline** (RDR-009, `PromptEvolutionWorkflow`):

- Weekly cron discovers eligible `Prompt` records, samples recent `AgentRun` records with quality metrics
- Calls `PromptEvolution::Mutate` (LLM-driven) to generate improved `PromptVersion` candidates
- Persists mutations via `PromptEvolution::CreateVariants`, then creates an `AbTest` comparing control vs variants
- `AbTestVariant` references `PromptVersion`, `AbTestAssignment` links `AgentRun` to variant, quality scores recorded via `AbTests::RecordResult`
- Winner promoted via `AbTests::PromoteWinner`

**Key constraint**: `AgentRun` has `prompt_version_id` — a 1:1 relationship. Every run uses exactly one prompt version. This clean coupling makes prompt evolution's sampling and attribution straightforward. Style guides do NOT have this 1:1 coupling — multiple guides are injected per run, so attribution must be designed from scratch.

### Technical Environment

- Rails 8 with PostgreSQL, Temporal workflows, GoodJob background jobs
- `AgentHarness.send_message` for all LLM calls
- Logidze for change tracking on `style_guides` (`log_data` jsonb column, `BEFORE INSERT OR UPDATE` trigger)
- Existing `AbTest` / `AbTestVariant` / `AbTestAssignment` infrastructure is tightly coupled to `Prompt` / `PromptVersion` (non-null FKs)

## Proposed Solution

### Architecture Overview

Style guide evolution follows the same four-stage pipeline as prompt evolution, but with its own version store and a per-guide singular-injection sampling model:

```
┌──────────────────────────────────────────────────────────────────────┐
│                    STYLE GUIDE EVOLUTION PIPELINE                     │
│                                                                       │
│  StyleGuideEvolutionJob (cron, weekly)                                │
│    └─► StyleGuideEvolutionWorkflow (Temporal)                         │
│          ├─► Step 1: SampleRunsActivity                               │
│          │     Sample agent runs from style_guide_run_exposures.      │
│          │     Use assignment-backed cohorts for both control and     │
│          │     variant arms whenever a style-guide A/B test is live.  │
│          │                                                            │
│          ├─► Step 2: GenerateMutationsActivity                        │
│          │     LLM proposes improved raw_content variants             │
│          │     (1-5 mutations, same pattern as PromptEvolution)       │
│          │                                                            │
│          ├─► Step 3: CreateStyleGuideVariantsActivity                 │
│          │     Persist mutations as StyleGuideVersion records         │
│          │     (review gate or auto-promote)                          │
│          │                                                            │
│          └─► Step 4: CreateStyleGuideAbTestActivity                   │
│                Creates StyleGuideAbTest: control vs new variants       │
│                InjectIntoPrompt extended to serve assigned-arm         │
│                content for the tested guide                           │
└──────────────────────────────────────────────────────────────────────┘
```

### Decision Rationale

1. **Parallel structure, not shared**: Style guide evolution uses its own version store and A/B test tables rather than shoehorning into the prompt-specific infrastructure. This avoids destabilizing the proven prompt evolution system and keeps each domain's schema clean.

2. **Reuse evolution patterns**: The four-stage pipeline (sample → mutate → persist → test) and the `Mutation` struct pattern from `PromptEvolution::Mutate` are reused directly. Only the domain objects differ.

3. **Singular injection for attribution**: Only one guide is varied per evolution cycle. All other guides stay at production version. This makes attribution tractable without requiring complex multi-factor analysis.

4. **Bitter Lesson**: Style guide quality improves through data (agent run outcomes), not intuition. The same statistical rigor applied to prompt evolution applies here.

### Technical Design

#### 1. StyleGuideVersion Table

Mirrors `PromptVersion` but scoped to `StyleGuide`:

```sql
CREATE TABLE style_guide_versions (
  id bigint PRIMARY KEY,
  style_guide_id bigint NOT NULL REFERENCES style_guides ON DELETE CASCADE,
  version integer NOT NULL,                    -- monotonic counter per style_guide
  raw_content text NOT NULL,                   -- immutable snapshot of content
  change_notes text,                           -- mutation description (strategy, reasoning)
  created_by character varying(50),            -- "evolution" | "manual" | "extraction"
  created_by_user_id bigint REFERENCES users,
  parent_version_id bigint REFERENCES style_guide_versions,  -- lineage chain
  review_status character varying(20),         -- "pending" | "approved" | "rejected"
  review_notes text,
  reviewed_at timestamp,
  reviewed_by_user_id bigint REFERENCES users,
  usage_count integer DEFAULT 0 NOT NULL,      -- times this version was injected
  avg_quality_score numeric(5,4),              -- rolling average from attributed runs
  retired_at timestamp,                        -- soft-delete
  created_at timestamp NOT NULL,
  updated_at timestamp NOT NULL

  UNIQUE(style_guide_id, version)
);
CREATE INDEX idx_style_guide_versions_on_style_guide_id ON style_guide_versions(style_guide_id);
CREATE INDEX idx_style_guide_versions_on_parent_version_id ON style_guide_versions(parent_version_id);
CREATE INDEX idx_style_guide_versions_on_retired_at ON style_guide_versions(retired_at);
```

**Why not reuse logidze history?** Logidze captures every `UPDATE` to any column (name, active flag, language), not just content changes. It lacks semantic versioning, immutable content snapshots, review gates, and parent lineage. Repurposing it would require backfilling a version extraction layer that is more complex than adding a dedicated table.

**Why not reuse `PromptVersion`?** `PromptVersion` has `template` and `system_prompt` fields specific to prompt rendering. `StyleGuideVersion` stores `raw_content` which is structurally different. The two version stores serve different domain objects and should not be coupled.

#### 2. StyleGuideAbTest / StyleGuideAbTestVariant Tables

Lightweight, style-guide-specific A/B test infrastructure (parallel to `AbTest` / `AbTestVariant` but not sharing tables):

```sql
CREATE TABLE style_guide_ab_tests (
  id bigint PRIMARY KEY,
  account_id bigint NOT NULL REFERENCES accounts,
  style_guide_id bigint NOT NULL REFERENCES style_guides ON DELETE CASCADE,
  control_version_id bigint NOT NULL REFERENCES style_guide_versions,
  winner_variant_id bigint REFERENCES style_guide_ab_test_variants,
  name character varying NOT NULL,
  status character varying NOT NULL DEFAULT 'draft',  -- draft | running | completed | cancelled
  min_samples_per_variant integer NOT NULL DEFAULT 30,
  confidence_threshold numeric NOT NULL DEFAULT 0.95,
  cached_analysis jsonb,
  analysis_samples_key character varying,
  started_at timestamp,
  completed_at timestamp,
  created_at timestamp NOT NULL,
  updated_at timestamp NOT NULL
);
-- At most one running style-guide experiment per account cohort.
-- This keeps each AgentRun attributable to exactly one experimental guide.
CREATE UNIQUE INDEX idx_style_guide_ab_tests_one_running_per_account
  ON style_guide_ab_tests(account_id) WHERE (status = 'running');

CREATE TABLE style_guide_ab_test_variants (
  id bigint PRIMARY KEY,
  style_guide_ab_test_id bigint NOT NULL REFERENCES style_guide_ab_tests ON DELETE CASCADE,
  style_guide_version_id bigint NOT NULL REFERENCES style_guide_versions,
  is_control boolean NOT NULL DEFAULT false,
  sample_count integer NOT NULL DEFAULT 0,
  total_quality_score numeric(10,4) NOT NULL DEFAULT 0.0,
  avg_quality_score numeric(5,4),
  created_at timestamp NOT NULL,
  updated_at timestamp NOT NULL,
  UNIQUE(style_guide_ab_test_id, style_guide_version_id)
);
-- At most one control per test (partial unique index; not valid as inline CONSTRAINT)
CREATE UNIQUE INDEX idx_style_guide_ab_test_variants_one_control
  ON style_guide_ab_test_variants(style_guide_ab_test_id) WHERE (is_control = true);
```

**Note on variant count limits:** The initial implementation should mirror the existing prompt A/B path and enforce the max-3-non-control-variants limit explicitly in `StyleGuideAbTestVariant` with `validate :style_guide_ab_test_variant_count_within_limit, on: :create`. This keeps the style-guide pipeline aligned with `AbTestVariant` rather than inventing a stricter database-only rule in one evolution system first.

**Why parallel tables instead of extending `AbTest`?** The existing `AbTest` / `AbTestVariant` tables have non-null FKs to `prompt_id` and `control_version_id` / `prompt_version_id`. Making them polymorphic would require a migration that touches every existing A/B test record and risks breaking the prompt evolution pipeline. A parallel structure keeps each evolution domain isolated and independently testable.

#### 3. StyleGuideRunExposure Table

Sampling cannot infer historical guide usage from `account_id` / `project_id` scope rules alone. The effective guide set for a run can change after the fact because of shadowing, deactivation, edits, or changed resolution order. We therefore persist the exact resolved guide/version pairs that were injected into each `AgentRun`.

```sql
CREATE TABLE style_guide_run_exposures (
  id bigint PRIMARY KEY,
  agent_run_id bigint NOT NULL REFERENCES agent_runs ON DELETE CASCADE,
  style_guide_id bigint REFERENCES style_guides ON DELETE SET NULL,
  style_guide_version_id bigint NOT NULL REFERENCES style_guide_versions,
  guide_name character varying NOT NULL,         -- denormalized identity preserved across guide deletion
  source_scope character varying(20) NOT NULL,  -- project | account | global
  position integer NOT NULL,                    -- prompt ordering for debugging/replay
  injected_via character varying(50) NOT NULL, -- BuildForIssue | BuildForPr | CreateAgentRunActivity
  style_guide_ab_test_assignment_id bigint REFERENCES style_guide_ab_test_assignments,
  created_at timestamp NOT NULL,
  updated_at timestamp NOT NULL,
  UNIQUE(agent_run_id, style_guide_id)
);
CREATE INDEX idx_style_guide_run_exposures_on_style_guide_id_and_created_at
  ON style_guide_run_exposures(style_guide_id, created_at);
CREATE INDEX idx_style_guide_run_exposures_on_version_id
  ON style_guide_run_exposures(style_guide_version_id);
CREATE INDEX idx_style_guide_run_exposures_on_assignment_id
  ON style_guide_run_exposures(style_guide_ab_test_assignment_id);
```

`style_guide_version_id` points at the immutable content snapshot that actually shipped on the run, including the control version. Any run enrolled in a style-guide A/B test, whether assigned to control or a named variant, also gets a `style_guide_ab_test_assignment`; the exposure row remains the canonical "what shipped" record, and the assignment row scopes that exposure to a specific experiment arm.

#### 4. Mutation Prompt

`StyleGuideEvolution::Mutate` follows the same pattern as `PromptEvolution::Mutate`:

```ruby
module StyleGuideEvolution
  Mutation = Struct.new(
    :raw_content,          # The full mutated style guide content
    :strategy,             # refinement | restructuring | simplification | expansion
    :reasoning,            # LLM's explanation of what problem this addresses
    :expected_improvement, # LLM's prediction of why this should perform better
    keyword_init: true
  )

  class Mutate
    STRATEGIES = %w[refinement restructuring simplification expansion].freeze
    MAX_MUTATION_COUNT = 5
    MIN_MUTATION_COUNT = 1

    def self.call(style_guide:, quality_metrics:, sample_outputs:, options: {})
      new(style_guide, quality_metrics, sample_outputs, options).mutate
    end

    def mutate
      response = request_mutations
      filtered = apply_guardrails(parse_mutations(response))
      raise InsufficientMutationsError, "Fewer than #{MIN_MUTATION_COUNT} mutations passed guardrails" if filtered.size < MIN_MUTATION_COUNT

      filtered
    end

    private

    def build_meta_prompt
      # Renders a meta-prompt with:
      # - Current style guide raw_content (redacted, truncated)
      # - Style guide metadata (name, language, scope)
      # - Performance data: sample size, avg/max/min quality scores
      # - Sample outputs: up to 3 successes and 3 failures from agent runs
      #   where this guide was injected (produced good vs bad code)
      # - Mutation strategies with descriptions
      # - Hard guardrails (see below)
    end

    def guardrails_section
      # Explicitly included in every mutation prompt:
      # 1. Preserve all section headers (## Section Name) from the original
      # 2. Do not remove any rule that references security, auth, or data integrity
      # 3. The total content length must be within 50% of the original
      # 4. The language/framework conventions must remain consistent
      # 5. If a rule has a MUST/SHOULD/MAY prefix, preserve the severity level
    end

    def parse_mutations(response)
      # Clean LLM output, parse JSON, validate:
      # - raw_content must be non-blank, under 50,000 chars
      # - Must preserve all section headers from original
      # - Diff ratio (Levenshtein) must be between 0.1 and 0.5 vs original
      # - Strategy must be one of allowed strategies
      # - Security-related passages must not be removed (regex guard)
    end
  end
end
```

**Guardrails summary:**

| Guardrail | Mechanism | Failure behavior |
|---|---|---|
| Section header preservation | Validate all `##`-prefixed headers from original appear in mutation | Reject mutation |
| Security rule retention | Regex match for patterns like `never`, `must not`, `do not`, `sanitize`, `validate`, `authenticate` | Reject mutation |
| Content length drift | `new_content.bytesize` must be 50%-200% of original | Reject mutation |
| Diff ratio bounds | Levenshtein distance ratio must be > 0.1 (too similar) and < 0.5 (too different) | Reject mutation |
| Review gate | `review_status = "pending"` requires human approval before activation | Variant stays pending |
| Minimum quality threshold | If avg_quality_score >= 0.85, skip evolution (guide is already performing well) | Skip cycle |

#### 5. Sampling and Attribution

This is the critical innovation over prompt evolution. The approach: **singular injection with assignment tracking**.

**How it works:**

1. When an `AgentRun` prompt is being assembled through any production run path:
   - Resolve the applicable guides once through a shared helper that returns the exact injected set
   - Persist one `StyleGuideRunExposure` row per injected guide/version on that run
   - Check whether the account has a single active `StyleGuideAbTest`
   - Verify that the test's `style_guide_id` is present in the resolved guide set for this project
   - If yes, enroll the run into the test by calling `StyleGuideAbTests::Assign`, which chooses one arm from the assignment-backed cohort: the control `StyleGuideAbTestVariant` or one of the experimental variants
   - For the tested guide, inject the assigned version content instead of inferring control from the current production row
   - Create a `StyleGuideAbTestAssignment` linking the `AgentRun` to the chosen `StyleGuideAbTestVariant`, and attach that assignment to the corresponding `StyleGuideRunExposure`
   - All other guides inject their production content as normal

2. When `QualityMetrics::Collect` records metrics for the agent run:
   - Look up the `StyleGuideAbTestAssignment` for this run
   - Call `StyleGuideAbTests::RecordResult` to update the assigned arm's sample_count and avg_quality_score
   - Also record the quality score on the `StyleGuideVersion.avg_quality_score` for the evolution sampling stage

3. The `StyleGuideEvolutionWorkflow` sample stage queries:
   - `StyleGuideRunExposure` records from the last 14 days for the target `style_guide_id`
   - Joined to `AgentRun` / quality metrics for outcome data
   - Joined to `StyleGuideAbTestAssignment` for every run participating in a style-guide A/B test, so `StyleGuideAbTests::Analyze` compares assignment-backed control and variant cohorts from the same test window
   - Non-test production runs remain visible through exposures alone for version-level quality sampling, but they are excluded from per-test control-vs-variant analysis unless they were explicitly assigned into that test

**Assignment table for all test arms:**

```sql
CREATE TABLE style_guide_ab_test_assignments (
  id bigint PRIMARY KEY,
  style_guide_ab_test_id bigint NOT NULL REFERENCES style_guide_ab_tests ON DELETE CASCADE,
  style_guide_ab_test_variant_id bigint NOT NULL REFERENCES style_guide_ab_test_variants,
  agent_run_id bigint NOT NULL REFERENCES agent_runs,
  quality_score numeric(5,4),                 -- recorded when run completes
  created_at timestamp NOT NULL,
  updated_at timestamp NOT NULL,
  UNIQUE(style_guide_ab_test_id, agent_run_id) -- one control-or-variant assignment per run per test
);
CREATE INDEX idx_style_guide_ab_test_assignments_on_agent_run_id
  ON style_guide_ab_test_assignments(agent_run_id);
```

**Why the extra exposure table?** Without it, sampling would guess historical guide usage from current account/project state. That breaks as soon as a project guide shadows an account guide, a guide is edited or deactivated after the run, or the resolver changes over time. `StyleGuideRunExposure` makes the sample stage read the exact runtime decision instead of a lossy reconstruction.

**Why singular injection?** If we tried to simultaneously evolve all 3-7 style guides injected per run, the combinatorial explosion would make statistical attribution impossible. By varying only one guide per evolution cycle, and by allowing only one running style-guide A/B test per account cohort, we get clean 1:1 attribution between the assigned arm and outcome for every enrolled `AgentRun` while still recording the full control exposure set.

**Fallback: whole-bundle attribution.** For a future phase, when all individual guides have converged, the system could treat the entire resolved guide set as a single configuration bundle and run multi-factor experiments. This is out of scope for the initial implementation.

#### 6. Control vs Variant Assignment

At agent run setup time, inside the shared style-guide prompt builder used by `BuildForIssue`, `BuildForPr`, and the issue `custom_prompt` branch in `CreateAgentRunActivity`:

```ruby
def maybe_assign_style_guide_variant(agent_run, resolved_guides)
  ab_test = StyleGuideAbTest.running.find_by(account_id: agent_run.account_id)
  return {} unless ab_test

  guide = resolved_guides.find { |resolved_guide| resolved_guide.id == ab_test.style_guide_id }
  return {} unless guide

  assignment = StyleGuideAbTests::Assign.call(
    style_guide_ab_test: ab_test,
    agent_run: agent_run
  )

  {
    guide.name => {
      raw_content: assignment.variant.style_guide_version.raw_content
    }
  }
end
```

`StyleGuides::InjectIntoPrompt` is extended to accept an optional `overrides` hash and an optional `agent_run:` for exposure recording. The override for the tested guide comes from the chosen assignment arm, including the control arm when the run is enrolled in a test. Overrides specify only `raw_content` (variant and control arms go through the same rendering path), and `StyleGuides::BuildInjectedGuideSet` runs `StyleGuides::Compress` on the override content when the production `style_guides` row has `compressed_content`, so both arms use the same byte-budget pipeline:

```ruby
module StyleGuides
  class InjectIntoPrompt
    def self.call(prompt:, project:, agent_run: nil, overrides: {})
      resolved_guides = StyleGuides::BuildInjectedGuideSet.call(project: project, overrides: overrides)
      resolved_guides.each do |resolved_guide|
        content = StyleGuides::RenderContentForPrompt.call(
          raw_content: resolved_guide.raw_content,
          compressed_content: resolved_guide.compressed_content,
          project: project
        )
        # inject content into prompt
      end
      StyleGuides::RecordRunExposures.call(agent_run: agent_run, resolved_guides: resolved_guides) if agent_run
    end
  end
end
```

The production path and the experimental path therefore share the same byte-budget semantics:

- `BuildInjectedGuideSet` detects override content on the tested guide and runs `StyleGuides::Compress` on it when the production `style_guides` row has `compressed_content`, so every arm (control and variant) receives content from the same source.
- If compression is unavailable or fails for an arm, both paths fall back to the same project-budgeted raw-content truncation logic via `RenderContentForPrompt`.
- Large variants cannot bypass the existing prompt budget merely because they came from `StyleGuideVersion`.

Each style guide can have many historical A/B tests, but the scheduler may run only one style-guide A/B test per account at a time. Different accounts can still run style-guide experiments concurrently because their `AgentRun` cohorts are disjoint.

#### 7. Scope Eligibility

| Scope | Eligible for evolution? | Rationale |
|---|---|---|
| **Global** (`account_id: nil, project_id: nil`) | **No** | Global defaults are system-wide templates seeded by Paid developers. Autonomous drift of global defaults could negatively impact all tenants. Manual updates only. |
| **Account** (`account_id: present, project_id: nil`) | **Yes** | Account-level guides represent that tenant's conventions. Evolution is scoped to that account's agent runs. |
| **Project** (`project_id: present`) | **Yes** | Project-level guides represent project-specific conventions. Evolution is scoped to that project's runs (which are a subset of the account's runs). |

The `StyleGuideEvolutionJob` cron filters to account-level and project-level guides only. Global guides are excluded from discovery.

**Edge case: newly seeded account guides.** When an account is provisioned with a default style guide (via `Onboarding::ProvisionDefaults`), that guide starts with `raw_content` copied from the global default. It is eligible for evolution because it belongs to the account. The global original remains untouched.

### Implementation Example

```ruby
# app/services/style_guide_evolution/mutate.rb
module StyleGuideEvolution
  class Mutate
    Mutation = Struct.new(
      :raw_content, :strategy, :reasoning, :expected_improvement,
      keyword_init: true
    )

    STRATEGIES = %w[refinement restructuring simplification expansion].freeze
    DEFAULT_MODEL = "claude-sonnet-4-6"
    TIMEOUT = 60
    MAX_MUTATION_COUNT = 5

    def self.call(style_guide:, quality_metrics:, sample_outputs:, options: {})
      new(style_guide, quality_metrics, sample_outputs, options).mutate
    end

    def initialize(style_guide, quality_metrics, sample_outputs, options)
      @style_guide = style_guide
      @quality_metrics = quality_metrics
      @sample_outputs = sample_outputs
      @options = options
    end

    def mutate
      response = request_mutations
      filtered = apply_guardrails(parse_mutations(response))
      raise InsufficientMutationsError, "Fewer than #{MIN_MUTATION_COUNT} mutations passed guardrails" if filtered.size < MIN_MUTATION_COUNT

      filtered
    end

    private

    def request_mutations
      response = AgentHarness.send_message(
        build_meta_prompt,
        provider: :claude,
        model: DEFAULT_MODEL,
        timeout: TIMEOUT,
        tools: :none,
        **Llm::TextMode.options
      )

      response.output if response.success?
    end

    def apply_guardrails(mutations)
      mutations.select do |mutation|
        preserves_sections?(mutation) &&
        preserves_security_rules?(mutation) &&
        acceptable_length_drift?(mutation) &&
        acceptable_diff_ratio?(mutation)
      end
    end
  end
end
```

```ruby
# app/models/style_guide_version.rb
class StyleGuideVersion < ApplicationRecord
  belongs_to :style_guide
  belongs_to :parent_version, class_name: "StyleGuideVersion", optional: true
  belongs_to :created_by_user, class_name: "User", optional: true
  belongs_to :reviewed_by_user, class_name: "User", optional: true

  has_many :style_guide_ab_test_variants, dependent: :restrict_with_error
  has_many :style_guide_ab_test_assignments, through: :style_guide_ab_test_variants

  scope :active, -> { where(retired_at: nil) }
  scope :approved, -> { where(review_status: %w[approved nil]) }
  scope :pending_review, -> { where(review_status: "pending") }

  IMMUTABLE_ATTRIBUTES = %w[
    raw_content version style_guide_id created_by_user_id
    parent_version_id change_notes created_by
  ].freeze

  validate :immutable_content, on: :update

  private

  def immutable_content
    IMMUTABLE_ATTRIBUTES.each do |attr|
      errors.add(attr, "is immutable") if send("#{attr}_changed?")
    end
  end
end
```

```ruby
# app/models/style_guide_ab_test_variant.rb
class StyleGuideAbTestVariant < ApplicationRecord
  MAX_NON_CONTROL_VARIANTS = 3

  belongs_to :style_guide_ab_test
  belongs_to :style_guide_version

  validates :sample_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :style_guide_version_belongs_to_same_guide
  validate :style_guide_ab_test_variant_count_within_limit, on: :create

  private

  def style_guide_version_belongs_to_same_guide
    return if style_guide_version.nil? || style_guide_ab_test.nil?

    if style_guide_version.style_guide_id != style_guide_ab_test.style_guide_id
      errors.add(:style_guide_version, "must belong to the same style guide as the A/B test")
    end
  end

  def style_guide_ab_test_variant_count_within_limit
    return if style_guide_ab_test.nil? || is_control?

    max_allowed = MAX_NON_CONTROL_VARIANTS + 1 # +1 for control
    if style_guide_ab_test.style_guide_ab_test_variants.count >= max_allowed
      errors.add(:base, "Style guide A/B test cannot have more than #{MAX_NON_CONTROL_VARIANTS} non-control variants")
    end
  end
end
```

```ruby
# app/models/style_guide_run_exposure.rb
class StyleGuideRunExposure < ApplicationRecord
  belongs_to :agent_run
  belongs_to :style_guide, optional: true
  belongs_to :style_guide_version
  belongs_to :style_guide_ab_test_assignment, optional: true

  enum :source_scope, {project: "project", account: "account", global: "global"}, validate: true
  enum :injected_via, {
    build_for_issue: "BuildForIssue",
    build_for_pr: "BuildForPr",
    create_agent_run_activity: "CreateAgentRunActivity"
  }, validate: true

  validates :guide_name, presence: true
  validates :position, numericality: {greater_than_or_equal_to: 0}
end
```

## Alternatives Considered

### Alternative 1: Repurpose logidze history as variants

**Pros**: No new table. Logidze already tracks every change.  
**Cons**: Logidze records all column changes (active toggle, name, language), not just content changes. No immutable snapshots — the trigger fires on every UPDATE, so "versions" include non-semantic changes. No parent lineage. No review gate. No usage statistics. Backfilling a version extraction layer would be more complex than adding a dedicated table. **Rejected.**

### Alternative 2: Extend existing AbTest tables with polymorphic subject

**Pros**: Reuses existing A/B test infrastructure. Single table for all A/B testing.  
**Cons**: Requires making `prompt_id` nullable and adding `subject_type`/`subject_id` to `ab_tests`. Every existing prompt A/B test record must be touched. Every query in the prompt evolution system must add `WHERE subject_type = 'Prompt'`. High risk of breaking a proven system. The refactor is larger than building a parallel structure. **Rejected.**

### Alternative 3: No A/B testing — apply mutations directly with rollback

**Pros**: Simplest implementation. Just create a new `StyleGuideVersion`, promote it, and roll back if quality degrades.  
**Cons**: No statistical validation. Catastrophic regressions are only caught after they affect many runs. Violates the Bitter Lesson principle — we'd be trusting the LLM's judgment of what's "better" rather than measuring actual outcomes. No way to know if a mutation helped or hurt. Rollback windows lose data. **Rejected.**

## Trade-offs and Consequences

### Positive

- Style guides improve autonomously over time, adapting to each account/project's actual code patterns and agent performance
- Same statistical rigor as prompt evolution (Welch's t-test, confidence thresholds, sample minimums)
- Immutable version store enables full lineage tracking, audit, and rollback
- Singular injection makes attribution tractable without complex multi-factor analysis

### Negative

- Five new database tables (`style_guide_versions`, `style_guide_ab_tests`, `style_guide_ab_test_variants`, `style_guide_ab_test_assignments`, `style_guide_run_exposures`) — schema grows
- ~30% of the prompt evolution code is conceptually duplicated (new service objects, new Temporal workflow, new cron job)
- Each style guide needs 30+ agent runs using it before an A/B test can statistically complete — may take weeks for low-traffic accounts
- Mutation quality depends entirely on LLM capability with style guide content (untested domain for current models)

### Risks and Mitigations

| Risk | Mitigation |
|---|---|
| LLM removes critical rule | Guardrails: section header preservation, security regex, diff ratio bounds, human review gate |
| Singular injection slows A/B test completion | Min sample threshold is configurable per account; low-traffic accounts can lower `min_samples_per_variant` |
| Evolution degrades guide quality | Control group ensures no regression. If all variants are worse than control, the test completes with "no winner" and the control stays active |
| LLM cost for weekly mutations | Mutation is cheap (one short LLM call per guide per week). Guides with `avg_quality_score >= 0.85` skip mutation entirely. |
| Sampling misattributes runs after guide edits or shadowing changes | Persist `style_guide_run_exposures` at runtime and sample from those immutable exposure records |

## Implemented Scope

The accepted scope shipped in July 2026 and was reconciled against the repository on Tuesday, August 4, 2026.

### Shipped components

1. **Version store and current-version pointers**
   - `style_guide_versions`, `style_guide_ab_tests`, `style_guide_ab_test_variants`, `style_guide_ab_test_assignments`, and `style_guide_run_exposures` are present in `db/schema.rb`.
   - `StyleGuideVersion`, `StyleGuideAbTest`, `StyleGuideAbTestVariant`, `StyleGuideAbTestAssignment`, and `StyleGuideRunExposure` implement the model layer and invariants.

2. **Mutation, sampling, and persistence**
   - `StyleGuideEvolution::Mutate`, `StyleGuideEvolution::SampleRuns`, and `StyleGuideEvolution::CreateVariants` implement the generation pipeline.

3. **A/B testing and quality attribution**
   - `StyleGuideAbTests::Assign`, `StyleGuideAbTests::Analyze`, `StyleGuideAbTests::RecordResult`, and `StyleGuideAbTests::PromoteWinner` implement enrollment, scoring, statistical analysis, and winner promotion.

4. **Runtime injection and exposure capture**
   - `StyleGuides::InjectIntoPrompt` resolves the effective version, serves the assigned A/B variant when present, and records `StyleGuideRunExposure` rows for each injected guide.

5. **Workflow and scheduling**
   - `StyleGuideEvolutionJob` discovers eligible account-level and project-level guides.
   - `Workflows::StyleGuideEvolutionWorkflow` and the style-guide Temporal activities orchestrate sample → mutate → persist → create test.

### Accepted implementation divergence

The shipped runtime path keeps exposure recording inside `StyleGuides::InjectIntoPrompt` rather than extracting separate `StyleGuides::RecordRunExposures`, `BuildInjectedGuideSet`, and `RenderContentForPrompt` service objects. The audit found this to be a consolidation choice, not a functional gap.

### Dependencies

- [RDR-009](RDR-009-prompt-evolution.md): Reuses `PromptEvolution::Mutate` pattern, the `Mutation` struct convention, and the four-stage pipeline architecture
- PR #2249: Initial global style guide seed set (guides must exist before they can be evolved)

## Validation

### Testing Approach

- **Unit tests**: `StyleGuideEvolution::Mutate` (mutation parsing, guardrail enforcement), `StyleGuideAbTests::Assign` (variant selection, idempotency), `StyleGuideAbTests::Analyze` (statistical correctness)
- **Integration tests**: `StyleGuideEvolutionWorkflow` end-to-end (sample → mutate → persist → test), `StyleGuides::InjectIntoPrompt` with control/variant assignment overrides and exposure recording, `CreateAgentRunActivity` issue prompt path recording the same exposures as `BuildForIssue`
- **Contract tests**: `StyleGuideVersion` immutability, `StyleGuideAbTest` state machine transitions, `StyleGuideAbTestVariant` non-control variant count limit
- **Existing tests must pass**: Prompt evolution pipeline unchanged, style guide injection unchanged for non-experimental guides

### Test Scenarios

1. **Mutation guardrail — section preservation**: Mutate a guide with sections `## Naming` and `## Error Handling`. Assert mutation preserves both headers.
2. **Mutation guardrail — security retention**: Mutate a guide containing "Never commit secrets to source control." Assert the phrase or equivalent appears in every mutation.
3. **Attribution accuracy**: Create an A/B test with control + 2 variants. Run 100 simulated agent runs. Assert every enrolled run has a `style_guide_ab_test_assignment`, `style_guide_run_exposures` records the exact guide/version shipped on each run, and quality scores are attributed to the correct control or variant arm.
4. **Winner promotion**: Create a test where variant significantly outperforms control. Assert `StyleGuideAbTests::PromoteWinner` updates `style_guide.current_version`.
5. **Global guide immunity**: Assert `StyleGuideEvolutionJob` does not discover global guides.
6. **Account-level exclusivity**: Attempt to start a second running style-guide A/B test for the same account. Assert validation rejects it while allowing a concurrent test in a different account.

### Performance

- Mutation LLM call: ~5-10 seconds per guide per week
- Style guide injection with variant override: < 1ms overhead (hash lookup)
- Assignment and exposure recording at run setup: one idempotent upsert plus one row per injected guide, negligible overhead at current guide counts
- Quality score recording: atomic increment on `style_guide_ab_test_variants`, batched with existing `AbTests::RecordResult`

### Security

- No new attack surface — evolution runs inside the existing Temporal worker, not exposed to containers
- Mutations are LLM-generated but validated through guardrails before persistence
- Review gate ensures human approval before any mutation goes live (when review is enabled on the account)
- Global guides are immune to autonomous drift

## References

### Requirements & Standards

- [RDR-009](RDR-009-prompt-evolution.md): Prompt Evolution system design
- [docs/PROMPT_EVOLUTION.md](../PROMPT_EVOLUTION.md): Full system design document
- `app/services/prompt_evolution/mutate.rb`: Reference implementation for mutation generation

### Research Resources

- `StyleGuides::InjectIntoPrompt` injection paths: `app/services/prompts/build_for_issue.rb:111`, `app/services/prompts/build_for_pr.rb:127`
- Issue `custom_prompt` bypass path that must be folded into the same resolver: `app/temporal/activities/create_agent_run_activity.rb:45`
- Deferred chat-session rendering path (requires its own attribution model): `app/services/chat_sessions/build_system_prompt.rb:178`
- A/B test analysis: `AbTests::Analyze` (`app/services/ab_tests/analyze.rb`), `AbTests::Statistics.welch_t_test`
- Prompt version model: `app/models/prompt_version.rb`
- Style guide model: `app/models/style_guide.rb`
- Style guide extraction: `app/services/style_guides/extract.rb`

## Notes

- The `StyleGuideVersion` table does **not** store `compressed_content`. Compression is a rendering optimization applied at injection time, not a versioned artifact. Only immutable `raw_content` snapshots are versioned.
- The canonical production read path remains the `style_guides` row. `StyleGuide#content_for_prompt` continues to read `style_guides.raw_content` / `style_guides.compressed_content`, and `StyleGuides::RenderContentForPrompt` becomes the shared helper behind both normal injection and experiment overrides.
- `StyleGuideRunExposure` is the canonical sampling source for evolution. The workflow should never reconstruct historical guide usage from current scope filters alone. The `style_guide_id` FK uses `ON DELETE SET NULL` (not `CASCADE`) and `guide_name` is denormalized onto the row so that exposure records survive guide deletion intact for historical analysis and audit.
- Winner promotion is therefore a mirror step, not a pointer flip only: promoting `current_version` must also copy that version's `raw_content` onto `style_guides.raw_content`, clear `style_guides.compressed_content`, and enqueue `StyleGuideCompressionJob`. Production prompts immediately pick up the new raw content via the existing fallback path, then pick up refreshed compressed content when compression completes.
- The `StyleGuide.current_version` pointer records which immutable snapshot is live; it is not a second runtime content source. Manual edits to `style_guide.raw_content` (via the UI) likewise create a new `StyleGuideVersion`, update the row-level canonical content, and repoint `current_version`.
- Logidze continues to track all changes for audit purposes alongside the version store. Version records capture the semantic content evolution; logidze captures the full operational history.
