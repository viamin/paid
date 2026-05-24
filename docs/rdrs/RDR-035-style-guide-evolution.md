# RDR-035: Style Guide Evolution

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-05-24
- **Status**: Proposed
- **Type**: Architecture
- **Priority**: High
- **Related Issues**: #2254, #2249
- **Related RDRs**: [RDR-009](RDR-009-prompt-evolution.md) (Prompt Evolution)
- **Related Tests**: (to be created during implementation)

## Problem Statement

The prompt evolution pipeline (`PromptEvolution::Mutate`, `PromptEvolutionWorkflow`) currently only mutates `Prompt` / `PromptVersion` records. `StyleGuide` records are versioned via logidze for audit purposes but are never evolved. PR #2249 seeded an initial set of global style guides on the expectation that they would later be improved over time by the evolution code, but there is no mechanism to do so.

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
- **No `style_guide_versions` table exists** — there is no immutable version store, no parent lineage, no usage statistics per version

**Style guide injection** happens at prompt-build time via `StyleGuides::InjectIntoPrompt`:

- Called by `BuildForIssue`, `BuildForPr`, and `BuildSystemPrompt`
- Resolves applicable guides via `StyleGuide.resolve_for(project)` (specificity inheritance: project > account > global)
- Injects formatted guides into the prompt within a byte budget

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
│          │     Sample agent runs where THIS guide was injected.       │
│          │     Attribute quality via style_guide_ab_test_assignments. │
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
│                InjectIntoPrompt extended to serve variant content      │
│                for experimental guides                                │
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
  avg_quality_score numeric(4,2),              -- rolling average from attributed runs
  retired_at timestamp,                        -- soft-delete
  created_at timestamp NOT NULL,
  updated_at timestamp NOT NULL,

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
  updated_at timestamp NOT NULL,

  -- At most one running test per style guide
  CONSTRAINT idx_style_guide_ab_tests_one_running
    UNIQUE(style_guide_id) WHERE (status = 'running')
);

CREATE TABLE style_guide_ab_test_variants (
  id bigint PRIMARY KEY,
  style_guide_ab_test_id bigint NOT NULL REFERENCES style_guide_ab_tests ON DELETE CASCADE,
  style_guide_version_id bigint NOT NULL REFERENCES style_guide_versions,
  is_control boolean NOT NULL DEFAULT false,
  sample_count integer NOT NULL DEFAULT 0,
  total_quality_score numeric NOT NULL DEFAULT 0.0,
  avg_quality_score numeric,
  created_at timestamp NOT NULL,
  updated_at timestamp NOT NULL,

  UNIQUE(style_guide_ab_test_id, style_guide_version_id),
  -- At most one control per test
  UNIQUE(style_guide_ab_test_id) WHERE (is_control = true),
  -- At most 3 non-control variants
  CONSTRAINT chk_max_experimental_variants
    CHECK (is_control = true OR style_guide_ab_test_id IN (
      SELECT style_guide_ab_test_id FROM style_guide_ab_test_variants
      WHERE is_control = false
      GROUP BY style_guide_ab_test_id
      HAVING count(*) <= 3
    ))
);
```

**Why parallel tables instead of extending `AbTest`?** The existing `AbTest` / `AbTestVariant` tables have non-null FKs to `prompt_id` and `prompt_version_id`. Making them polymorphic would require a migration that touches every existing A/B test record and risks breaking the prompt evolution pipeline. A parallel structure keeps each evolution domain isolated and independently testable.

#### 3. Mutation Prompt

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
      parse_mutations(response)
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

#### 4. Sampling and Attribution

This is the critical innovation over prompt evolution. The approach: **singular injection with assignment tracking**.

**How it works:**

1. When an `AgentRun` is being set up and `StyleGuides::InjectIntoPrompt` is called:
   - Check if there is an active `StyleGuideAbTest` for any of the resolved style guides
   - If yes, for the experimental guide, inject the assigned variant content instead of the production (current) content
   - Create a `StyleGuideAbTestAssignment` linking the `AgentRun` to the `StyleGuideAbTestVariant`
   - All other guides inject their production content as normal

2. When `QualityMetrics::Collect` records metrics for the agent run:
   - Look up the `StyleGuideAbTestAssignment` for this run
   - Call `StyleGuideAbTests::RecordResult` to update the variant's sample_count and avg_quality_score
   - Also record the quality score on the `StyleGuideVersion.avg_quality_score` for the evolution sampling stage

3. The `StyleGuideEvolutionWorkflow` sample stage queries:
   - `AgentRun` records from the last 14 days
   - Filtered to runs where the target style guide was injected (accounts/projects that use this guide)
   - Joined via `StyleGuideAbTestAssignment` to get quality scores attributed to each variant

**Attribution table:**

```sql
CREATE TABLE style_guide_ab_test_assignments (
  id bigint PRIMARY KEY,
  style_guide_ab_test_id bigint NOT NULL REFERENCES style_guide_ab_tests ON DELETE CASCADE,
  style_guide_ab_test_variant_id bigint NOT NULL REFERENCES style_guide_ab_test_variants,
  agent_run_id bigint NOT NULL REFERENCES agent_runs,
  quality_score numeric,                       -- recorded when run completes
  created_at timestamp NOT NULL,
  updated_at timestamp NOT NULL,

  UNIQUE(style_guide_ab_test_id, agent_run_id) -- one assignment per run per test
);
CREATE INDEX idx_style_guide_ab_test_assignments_on_agent_run_id
  ON style_guide_ab_test_assignments(agent_run_id);
```

**Why singular injection?** If we tried to simultaneously evolve all 3-7 style guides injected per run, the combinatorial explosion would make statistical attribution impossible. By varying only one guide per evolution cycle (the one with its own A/B test running), we get clean 1:1 attribution between variant and outcome.

**Fallback: whole-bundle attribution.** For a future phase, when all individual guides have converged, the system could treat the entire resolved guide set as a single configuration bundle and run multi-factor experiments. This is out of scope for the initial implementation.

#### 5. Control vs Variant Assignment

At agent run setup time, inside `RunAgentActivity` (or the equivalent prompt-build path):

```ruby
def maybe_assign_style_guide_variant(agent_run, resolved_guides)
  resolved_guides.each do |guide|
    ab_test = guide.active_style_guide_ab_test
    next unless ab_test

    assignment = StyleGuideAbTests::Assign.call(
      style_guide_ab_test: ab_test,
      agent_run: agent_run
    )

    # Override this guide's content with the variant version
    variant_version = assignment.variant.style_guide_version
    guide.instance_variable_set(:@override_content, variant_version.raw_content)
  end
end
```

`StyleGuides::InjectIntoPrompt` is extended to accept an optional `overrides` hash:

```ruby
module StyleGuides
  class InjectIntoPrompt
    def self.call(prompt:, project:, overrides: {})
      guides = StyleGuide.resolve_for(project)
      guides.each do |guide|
        content = overrides[guide.name] || guide.content_for_prompt
        # inject content into prompt
      end
    end
  end
end
```

Each style guide can have at most one running A/B test (enforced by the unique partial index on `style_guide_ab_tests`). Multiple guides CAN each have their own test running concurrently — they vary independently.

#### 6. Scope Eligibility

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
      filtered
    end

    private

    def request_mutations
      agent_harness = AgentHarness.new(model: DEFAULT_MODEL)
      agent_harness.send_message(
        system: meta_prompt_system,
        messages: [{ role: "user", content: build_meta_prompt }],
        options: { timeout: TIMEOUT, tools: :none }
      )
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

- Four new database tables (`style_guide_versions`, `style_guide_ab_tests`, `style_guide_ab_test_variants`, `style_guide_ab_test_assignments`) — schema grows
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

## Implementation Plan

### Prerequisites

- [ ] Merge RDR-035 (this document)
- [ ] Ensure `StyleGuide` model has `has_many :versions` association prepared
- [ ] Verify logidze trigger on `style_guides` continues to work alongside the version table

### Steps

1. **Database migrations** (Phase A):
   - [ ] Create `style_guide_versions` table with indexes
   - [ ] Add `current_version_id` FK to `style_guides` table (nullable, referencing `style_guide_versions`)
   - [ ] Add `last_evolved_at` timestamp to `style_guides`
   - [ ] Create `style_guide_ab_tests` table
   - [ ] Create `style_guide_ab_test_variants` table
   - [ ] Create `style_guide_ab_test_assignments` table

2. **Models** (Phase A):
   - [ ] `StyleGuideVersion` model with associations, immutability validations, scopes
   - [ ] `StyleGuideAbTest` model with lifecycle (`draft → running → completed → cancelled`), associations
   - [ ] `StyleGuideAbTestVariant` model with sample tracking
   - [ ] `StyleGuideAbTestAssignment` model
   - [ ] `StyleGuide` model: add `belongs_to :current_version`, `has_many :versions`, `has_many :style_guide_ab_tests`
   - [ ] `AgentRun` model: add `has_many :style_guide_ab_test_assignments`

3. **Services** (Phase B):
   - [ ] `StyleGuideEvolution::Mutate` — LLM-driven mutation generation (parallel to `PromptEvolution::Mutate`)
   - [ ] `StyleGuideEvolution::SampleRuns` — sample agent runs for a given style guide
   - [ ] `StyleGuideEvolution::CreateVariants` — persist mutations as `StyleGuideVersion` records
   - [ ] `StyleGuideAbTests::Assign` — assign variant to agent run at injection time
   - [ ] `StyleGuideAbTests::RecordResult` — record quality score against variant
   - [ ] `StyleGuideAbTests::Analyze` — Welch's t-test comparing variants against control
   - [ ] `StyleGuideAbTests::PromoteWinner` — promote winning variant to `current_version`
   - [ ] `StyleGuides::InjectIntoPrompt` — add `overrides` parameter for experimental guides

4. **Temporal** (Phase B):
   - [ ] `StyleGuideEvolutionWorkflow` — orchestrate the four-stage pipeline
   - [ ] `SampleRunsActivity`, `GenerateMutationsActivity`, `CreateStyleGuideVariantsActivity`, `CreateStyleGuideAbTestActivity`

5. **Jobs** (Phase B):
   - [ ] `StyleGuideEvolutionJob` — weekly cron discovering eligible account/project guides

6. **Integration** (Phase C):
   - [ ] Wire `RunAgentActivity` to call `maybe_assign_style_guide_variant`
   - [ ] Wire `QualityMetrics::Collect` to call `StyleGuideAbTests::RecordResult`
   - [ ] Wire `StyleGuides::InjectIntoPrompt` throughout `BuildForIssue`, `BuildForPr`, `BuildSystemPrompt`

### Dependencies

- [RDR-009](RDR-009-prompt-evolution.md): Reuses `PromptEvolution::Mutate` pattern, the `Mutation` struct convention, and the four-stage pipeline architecture
- PR #2249: Initial global style guide seed set (guides must exist before they can be evolved)

## Validation

### Testing Approach

- **Unit tests**: `StyleGuideEvolution::Mutate` (mutation parsing, guardrail enforcement), `StyleGuideAbTests::Assign` (variant selection, idempotency), `StyleGuideAbTests::Analyze` (statistical correctness)
- **Integration tests**: `StyleGuideEvolutionWorkflow` end-to-end (sample → mutate → persist → test), `StyleGuides::InjectIntoPrompt` with overrides
- **Contract tests**: `StyleGuideVersion` immutability, `StyleGuideAbTest` state machine transitions
- **Existing tests must pass**: Prompt evolution pipeline unchanged, style guide injection unchanged for non-experimental guides

### Test Scenarios

1. **Mutation guardrail — section preservation**: Mutate a guide with sections `## Naming` and `## Error Handling`. Assert mutation preserves both headers.
2. **Mutation guardrail — security retention**: Mutate a guide containing "Never commit secrets to source control." Assert the phrase or equivalent appears in every mutation.
3. **Attribution accuracy**: Create an A/B test with control + 2 variants. Run 100 simulated agent runs. Assert quality scores are attributed to correct variants.
4. **Winner promotion**: Create a test where variant significantly outperforms control. Assert `StyleGuideAbTests::PromoteWinner` updates `style_guide.current_version`.
5. **Global guide immunity**: Assert `StyleGuideEvolutionJob` does not discover global guides.
6. **Multiple concurrent tests**: Run A/B tests for 2 different style guides simultaneously. Assert each agent run receives correct variant for each guide.

### Performance

- Mutation LLM call: ~5-10 seconds per guide per week
- Style guide injection with variant override: < 1ms overhead (hash lookup)
- Assignment at run setup: idempotent upsert, negligible overhead
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

- `StyleGuides::InjectIntoPrompt` injection paths: `app/services/prompts/build_for_issue.rb:111`, `app/services/prompts/build_for_pr.rb:127`, `app/services/chat_sessions/build_system_prompt.rb:178`
- A/B test analysis: `AbTests::Analyze` (`app/services/ab_tests/analyze.rb`), `AbTests::Statistics.welch_t_test`
- Prompt version model: `app/models/prompt_version.rb`
- Style guide model: `app/models/style_guide.rb`
- Style guide extraction: `app/services/style_guides/extract.rb`

## Notes

- The `StyleGuideVersion` table does **not** store `compressed_content`. Compression is a rendering optimization applied at injection time, not a versioned artifact. Only `raw_content` (the source of truth) is versioned.
- The existing `StyleGuideCompressionJob` continues to compress `current_version.raw_content` after a new version is promoted.
- The `StyleGuide.current_version` is set only when a version is approved (or auto-promoted if review is disabled). Manual edits to `style_guide.raw_content` (via the UI) also create a new version automatically via `before_save :create_version_if_content_changed`.
- Logidze continues to track all changes for audit purposes alongside the version store. Version records capture the semantic content evolution; logidze captures the full operational history.
