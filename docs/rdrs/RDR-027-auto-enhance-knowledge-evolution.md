# RDR-027: Auto-Enhance and Knowledge Base Evolution

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2026-04-23
- **Status**: Partially Implemented
- **Type**: Architecture
- **Priority**: High
- **Related RDRs**: [RDR-009](RDR-009-prompt-evolution.md) (Prompt Evolution), [RDR-021](RDR-021-knowledge-base.md) (Knowledge Base), [RDR-023](RDR-023-automation-modularization-architecture.md) (Automation Modularization)
- **Related Tests**: `spec/temporal/activities/analyze_issue_activity_spec.rb`, `spec/services/knowledge/usage_stats_spec.rb`, `spec/temporal/workflows/knowledge_evolution_workflow_spec.rb`

## Implementation Status

Partially implemented. Paid implements auto-enhance analysis runs, readiness routing, knowledge usage stats, knowledge evolution workflows, and recommendation UI. The remaining gap is usage attribution coverage: `EnhanceIssueActivity` passes `agent_run_id` into knowledge search/bundles, but `AnalyzeIssueActivity` and `Prompts::BuildForIssue` still have knowledge calls that do not provide an `agent_run_id`, so those paths do not fully feed knowledge usage tracking.

## Problem Statement

Paid's auto-pick feature selects issues and immediately starts `create_pr` agent runs. On legacy projects like HunthHelper — with years of code history, sparse issue descriptions, and evolving architecture — this wastes agent resources on issues that lack sufficient context for implementation. The agent discovers mid-run that critical information is missing, producing low-quality or failed PRs.

Three specific gaps exist:

1. **No readiness gate before auto-pick creates PRs** — Auto-pick jumps straight from issue selection to code generation, even when the issue description is vague, missing acceptance criteria, or lacks architectural context that the knowledge base doesn't cover.

2. **No visibility into which knowledge base data helps** — The system injects knowledge context into agent runs but never tracks which artifact types (routes, symbols, churn hotspots, etc.) are actually consumed or useful. There is no feedback loop from agent outcomes back to knowledge collection.

3. **No mechanism to evolve knowledge collection** — Unlike prompt evolution (RDR-009), there is no meta-agent analyzing knowledge gaps and recommending new collectors or deprecating ineffective ones.

Key requirements:

- **Context readiness assessment** — Before starting a `create_pr` run, evaluate whether the issue + knowledge base provide enough context to succeed
- **Automatic routing** — If context is insufficient, route to `enhance_issue` to ask clarifying questions instead of failing a PR run
- **Usage tracking** — Record which knowledge artifact types are consumed by each agent run
- **Gap analysis** — Periodically analyze enhance_issue outputs to identify knowledge gaps and recommend collector improvements
- **Per-project opt-in** — All features are project-level toggles; existing behavior is unchanged

## Context

### Background

The existing features that this builds on:

- **Auto-pick** (`Issues::AutoPick`, `Automation::Strategies::AutoPick`) selects issues by priority label, dependency ordering, and FIFO, then creates `create_pr` agent runs via `ProcessRunQueueJob`.
- **Issue enhancement** (`EnhanceIssueActivity`) calls an LLM directly (no container) to analyze issues, post clarifying questions, and apply GitHub labels. It supports a re-evaluation loop when the `paid-needs-input` label is removed.
- **Knowledge base** (RDR-021) collects project data via 8 registered collectors, stores as versioned artifacts with embeddings, and provides `ContextBundle::Build` and `Knowledge::Search` for retrieval.
- **Prompt evolution** (RDR-009) runs weekly via Temporal workflow to sample runs, generate mutations via LLM, create A/B tests, and statistically validate winners.
- **Automation framework** (RDR-023) provides `Automation::Decision`, `Automation::Context`, `Automation::Strategy`, and `Automation::Result` value objects for composable automation policies.

### Technical Environment

- Rails 8 with PostgreSQL, Temporal workflows, GoodJob background jobs
- `AgentHarness.send_message` for all LLM calls
- Docker containers for agent execution (but not for `enhance_issue` or the proposed `analyze_issue`)
- Existing `AgentRun::GOALS = %w[create_pr create_issue review enhance_issue]`
- Existing `Issue::PAID_STATES = %w[new planning in_progress completed failed needs_input recommend_close]`

## Proposed Solution

### Architecture Overview

Three interconnected subsystems, each independently deployable behind per-project feature flags:

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Auto-Pick Pipeline                          │
│                                                                     │
│  Auto-pick selects issue ──► auto_enhance_enabled?                 │
│                                │                                    │
│                           ┌────┴────┐                               │
│                           │ Yes     │ No                             │
│                           ▼         ▼                               │
│                    AnalyzeIssue   Create PR                         │
│                     Activity      (existing)                        │
│                        │                                            │
│                   ┌────┴────┐                                       │
│                   │         │                                       │
│             Sufficient  Insufficient                                │
│                   │         │                                       │
│                   ▼         ▼                                       │
│              Create PR   Enhance Issue                              │
│               (followup)  (followup)                                │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                     Knowledge Usage Tracking                        │
│                                                                     │
│  ContextBundle::Build  ──►  KnowledgeUsageStat  ◄── Knowledge::Search│
│       (per artifact type)         │                                  │
│                                   ▼                                  │
│                          Usage Stats Service                        │
│                          (aggregate queries)                        │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                    Knowledge Base Evolution                          │
│  (weekly cron, modeled on PromptEvolutionWorkflow)                  │
│                                                                     │
│  SampleEnhanceRuns ──► AnalyzeKnowledgeGaps ──► RecordRecs          │
│       Activity             Activity              Activity           │
│                                                     │                │
│                                                     ▼                │
│                                          KnowledgeRecommendation    │
│                                          (review UI for owner)      │
└─────────────────────────────────────────────────────────────────────┘
```

### 1. Auto-Enhance: The `analyze_issue` Goal

A new agent run goal `analyze_issue` that performs a lightweight context readiness assessment before committing to a full `create_pr` run.

**New `AnalyzeIssueActivity`** — a direct LLM call (like `EnhanceIssueActivity`):

1. Fetch GitHub issue + comments
2. Build knowledge context via `Knowledge::Search` + `Knowledge::ContextBundle::Build`
3. Call LLM with a readiness-assessment prompt
4. Parse structured JSON: `{ "sufficient_context": bool, "reasoning": "...", "missing_context_areas": [...] }`
5. Enqueue follow-up: `create_pr` if sufficient, `enhance_issue` if not
6. Track tokens

**Auto-pick integration**:

- New decision type `Decision.queue_analyze_issue_run(issue_id:)`
- `Issues::AutoPick` checks `project.auto_enhance_enabled?` and creates `analyze_issue` run instead of `create_pr`
- `AgentExecutionWorkflow` routes `analyze_issue` to `AnalyzeIssueActivity` (no container, no clone)

**Follow-up routing**:

- New service `AgentRuns::CreateFollowup` creates the next run in the sequence
- Follow-up runs inherit provider, project, and issue from the analysis run
- The existing unique index `idx_agent_runs_unique_active_issue` prevents duplicates

### 2. Knowledge Usage Tracking

A new `KnowledgeUsageStat` model records per-artifact-type consumption by each agent run.

**Data model**:

```ruby
create_table :knowledge_usage_stats do |t|
  t.references :agent_run, null: false, foreign_key: true
  t.references :project, null: false, foreign_key: true
  t.string :artifact_type, null: false    # "route", "symbol", "churn_hotspot", etc.
  t.string :goal, null: false             # "create_pr", "enhance_issue", "analyze_issue", etc.
  t.string :context_type, null: false     # "bundle" or "search"
  t.integer :artifact_count, default: 0
  t.integer :chunk_count, default: 0
  t.integer :token_count, default: 0
  t.jsonb :metadata, default: {}
  t.timestamps
end
```

Each row represents one artifact type consumed by one agent run through one channel. Unique index on `(agent_run_id, artifact_type, context_type)`.

**Instrumentation points**:

- `Knowledge::ContextBundle::Build` — accepts optional `agent_run_id:`, records artifact types included in the bundle
- `Knowledge::Search` — accepts optional `agent_run_id:`, records artifact types returned by search
- Both `AnalyzeIssueActivity` and `EnhanceIssueActivity` pass their agent run IDs
- `RunAgentActivity.inject_knowledge_into_prompt` passes the agent run ID for `create_pr` and `review` goals

**Aggregate stats** — `Knowledge::UsageStats` service provides:

- Usage by artifact type, filtered by project/goal/time range
- Correlation between knowledge usage and run success rates
- Most/least used artifact types

### 3. Knowledge Base Evolution

A periodic meta-agent (weekly cron, modeled on `PromptEvolutionWorkflow`) that analyzes enhance_issue outcomes to improve knowledge collection.

**Temporal workflow** — three activities in sequence:

1. **`SampleEnhanceRunsActivity`** — For each project, fetch recent `enhance_issue` runs where questions were asked. Extract: questions asked, knowledge context available (from `KnowledgeUsageStat`), user responses (from GitHub comments), subsequent run outcomes.

2. **`AnalyzeKnowledgeGapsActivity`** — Call LLM with sampled data + existing collector inventory + usage stats. LLM identifies: knowledge gaps, collector recommendations (new types to add), collector effectiveness (underperforming types to remove), and collector overlap.

3. **`RecordKnowledgeRecommendationsActivity`** — Persist recommendations as `KnowledgeRecommendation` records (pending/accepted/dismissed/implemented lifecycle).

**New model** — `KnowledgeRecommendation`:

```ruby
create_table :knowledge_recommendations do |t|
  t.references :project, null: false, foreign_key: true
  t.string :recommendation_type, null: false  # "add_collector", "remove_collector", etc.
  t.string :collector_type
  t.string :priority, default: "medium"
  t.text :description
  t.jsonb :evidence, default: {}
  t.string :status, default: "pending"
  t.datetime :dismissed_at
  t.text :dismissal_reason
  t.timestamps
end
```

**Review UI** — Project owners can accept or dismiss recommendations through a simple table interface.

### Project Configuration

Three new per-project settings (all default `false`, all opt-in):

| Setting | Purpose | Phase |
|---------|---------|-------|
| `auto_enhance_enabled` | Enables analyze_issue gate before auto-pick create_pr | Auto-Enhance |
| `knowledge_evolution_enabled` | Enables weekly knowledge gap analysis | Knowledge Evolution |

Both are independent — you can use auto-enhance without evolution analysis, or evolution analysis on manually-enhanced projects.

## Alternatives Considered

### 1. Dry-run mode on EnhanceIssueActivity instead of new goal

**Description**: Add a mode flag to the existing `EnhanceIssueActivity` that skips comment posting and just returns the readiness assessment.

**Rejected because**: Couples two distinct flows (analysis vs enhancement) into one activity. The analyze path has different outputs (no GitHub comment, different prompt, different follow-up routing), different workflow routing (immediate follow-up vs label-based re-evaluation), and different quality metrics. A separate goal keeps each activity focused and testable.

### 2. Inline knowledge gap analysis after each enhance_issue run

**Description**: Run gap analysis immediately after each `enhance_issue` completion.

**Rejected because**: Individual runs lack statistical power. A weekly batch can identify patterns across many runs (e.g., "5 different issues all asked about database schema"), which is far more actionable than analyzing one run at a time. Also avoids adding LLM cost to every enhance_issue run.

### 3. Per-artifact ID tracking (join table) instead of per-type counts

**Description**: Track exactly which artifact IDs were consumed by each run via a join table.

**Rejected because**: Orders of magnitude more storage. With ~20 artifact types per run, per-type counts require one row per type. Per-artifact tracking could require hundreds of rows per run. The aggregate patterns (which types are useful) are what matter for collector evolution — individual artifact tracking adds no value for that use case.

### 4. Always-on for auto-pick projects

**Description**: Make the analyze_issue gate automatic for all projects with `auto_pick_enabled`.

**Rejected because**: Adds latency (~30s LLM call) to every auto-pick cycle. For well-documented projects with good issue hygiene, this is unnecessary overhead. Per-project opt-in lets teams choose the tradeoff.

## Trade-offs and Consequences

### Positive Consequences

- **Higher PR success rate** — Issues get enhanced before agent execution, reducing wasted agent time on vague issues
- **Data-driven collector improvement** — Usage stats and gap analysis provide concrete evidence for knowledge base investment decisions
- **Minimal cost** — `analyze_issue` uses a lightweight LLM call (~30s, no container), much cheaper than a failed `create_pr` run
- **Incremental adoption** — Each subsystem is independently useful and opt-in
- **Extends existing patterns** — Follows the automation strategy/decision pattern (RDR-023) and the prompt evolution Temporal workflow pattern (RDR-009)

### Negative Consequences

- **Added latency** — Auto-pick adds ~30s for the analysis step before starting work
- **Additional LLM cost** — Each auto-pick cycle adds one analysis call; knowledge evolution adds one weekly call per project
- **New agent run goal** — Adds complexity to `AgentRun::GOALS` and the workflow routing

### Risks and Mitigations

| Risk | Mitigation |
|------|-----------|
| Analysis → enhance → recheck → analysis loop | `max_enhance_issue_reevaluation_rounds` (default 3) caps the loop; add `max_analysis_rounds` similarly |
| LLM hallucination in readiness assessment | The assessment is conservative — if uncertain, route to enhance_issue (ask the human) |
| Knowledge usage tracking adds write overhead | Upsert is lightweight (one row per artifact type per run); unique index prevents duplicates |
| Gap analysis produces low-quality recommendations | Recommendations are persisted as "pending" — project owner reviews before any collector changes |
| Race condition: duplicate analysis runs | Existing `idx_agent_runs_unique_active_issue` unique index handles this |

## Implementation Plan

### Phase 1: Auto-Enhance Core (P1)

**Prerequisites**: None — builds on existing auto-pick, enhance_issue, and knowledge features.

1. Add `auto_enhance_enabled` column to projects (migration)
2. Add `"analyze_issue"` to `AgentRun::GOALS`, predicates, and queue priority
3. Add `Decision.queue_analyze_issue_run` factory method
4. Add `"analyzed"` to `Issue::PAID_STATES`
5. Create `AnalyzeIssueActivity` (direct LLM call, knowledge context, structured JSON output)
6. Create `AgentRuns::CreateFollowup` service (routes to create_pr or enhance_issue)
7. Modify `Issues::AutoPick` to create `analyze_issue` run when `auto_enhance_enabled`
8. Wire `analyze_issue` goal in `AgentExecutionWorkflow`
9. Add project setting toggle to UI
10. Unit and integration tests

### Phase 2: Knowledge Usage Tracking (P2)

**Prerequisites**: None — can be developed in parallel with Phase 1.

1. Create `KnowledgeUsageStat` model and migration
2. Instrument `Knowledge::ContextBundle::Build` with `agent_run_id:` parameter
3. Instrument `Knowledge::Search` with `agent_run_id:` parameter
4. Wire tracking into `AnalyzeIssueActivity`, `EnhanceIssueActivity`, `RunAgentActivity`
5. Create `Knowledge::UsageStats` aggregate service
6. Add usage stats to knowledge dashboard

### Phase 3: Knowledge Base Evolution (P3)

**Prerequisites**: Phase 2 (needs `KnowledgeUsageStat` data).

1. Create `KnowledgeRecommendation` model and migration
2. Add `knowledge_evolution_enabled` project setting
3. Create `KnowledgeEvolutionJob` (GoodJob cron)
4. Create `KnowledgeEvolutionWorkflow` (Temporal)
5. Create `SampleEnhanceRunsActivity`
6. Create `AnalyzeKnowledgeGapsActivity` (LLM meta-agent)
7. Create `RecordKnowledgeRecommendationsActivity`
8. Add recommendation review UI (controller + views)
9. Wire cron schedule in `config/initializers/good_job.rb`

### Files to Create

| File | Phase |
|------|-------|
| `app/temporal/activities/analyze_issue_activity.rb` | 1 |
| `app/services/agent_runs/create_followup.rb` | 1 |
| `app/models/knowledge_usage_stat.rb` | 2 |
| `app/services/knowledge/usage_stats.rb` | 2 |
| `db/migrate/*_add_auto_enhance_enabled_to_projects.rb` | 1 |
| `db/migrate/*_create_knowledge_usage_stats.rb` | 2 |
| `db/migrate/*_create_knowledge_recommendations.rb` | 3 |
| `db/migrate/*_add_knowledge_evolution_enabled_to_projects.rb` | 3 |
| `app/models/knowledge_recommendation.rb` | 3 |
| `app/jobs/knowledge_evolution_job.rb` | 3 |
| `app/temporal/workflows/knowledge_evolution_workflow.rb` | 3 |
| `app/temporal/activities/sample_enhance_runs_activity.rb` | 3 |
| `app/temporal/activities/analyze_knowledge_gaps_activity.rb` | 3 |
| `app/temporal/activities/record_knowledge_recommendations_activity.rb` | 3 |
| `app/controllers/projects/knowledge_recommendations_controller.rb` | 3 |

### Files to Modify

| File | Phase | Change |
|------|-------|--------|
| `app/models/agent_run.rb` | 1 | Add `analyze_issue` goal, predicates, prompt method |
| `app/models/issue.rb` | 1 | Add `"analyzed"` to `PAID_STATES` |
| `app/models/project.rb` | 1,3 | Add settings, validations |
| `app/services/automation/decision.rb` | 1 | Add `queue_analyze_issue_run` |
| `app/services/automation/strategies/auto_pick.rb` | 1 | Route to analyze_issue when enabled |
| `app/services/issues/auto_pick.rb` | 1 | Create analyze_issue run |
| `app/temporal/workflows/agent_execution_workflow.rb` | 1 | Route analyze_issue goal |
| `app/services/knowledge/context_bundle/build.rb` | 2 | Add `agent_run_id:` tracking |
| `app/services/knowledge/search.rb` | 2 | Add `agent_run_id:` tracking |
| `app/temporal/activities/enhance_issue_activity.rb` | 2 | Wire usage tracking |
| `app/temporal/activities/run_agent_activity.rb` | 2 | Wire usage tracking |
| `app/services/knowledge/dashboard_stats.rb` | 2 | Add usage stats |
| `app/controllers/projects_controller.rb` | 1,3 | Permit new settings |
| `app/views/projects/edit.html.erb` | 1,3 | Add toggle UI |
| `config/routes.rb` | 3 | Add knowledge_recommendations routes |
| `config/initializers/good_job.rb` | 3 | Add cron schedule |

## Validation

### Testing Approach

- Unit tests for `AnalyzeIssueActivity` (mock GitHub client, knowledge search, LLM)
- Unit tests for `AgentRuns::CreateFollowup` (verify correct goal routing, duplicate handling)
- Unit tests for `KnowledgeUsageStat` recording in context bundle and search
- Unit tests for `Knowledge::UsageStats` aggregate queries
- Integration tests for full auto-pick → analyze → follow-up flow
- Workflow tests for `KnowledgeEvolutionWorkflow` (following `prompt_evolution_workflow_spec.rb` pattern)
- Activity tests for `AnalyzeKnowledgeGapsActivity` (mock LLM, verify structured output)

### Performance Validation

- `analyze_issue` LLM call completes in < 30 seconds
- Usage tracking upsert adds < 50ms per artifact type per run
- Knowledge evolution workflow completes in < 5 minutes per project
- Dashboard stats queries return in < 500ms

### Security Validation

- Usage stats are scoped to project (no cross-project data leakage)
- Knowledge recommendations are project-scoped
- LLM calls for gap analysis go through `AgentHarness` (no direct API calls)

## References

- RDR-009: Prompt Evolution System (Temporal workflow pattern)
- RDR-021: Knowledge Base Architecture (collector framework, data model)
- RDR-023: Automation Modularization Architecture (strategy/decision pattern)
- `app/temporal/activities/enhance_issue_activity.rb` (direct LLM call pattern)
- `app/services/prompt_evolution/` (meta-agent service pattern)
