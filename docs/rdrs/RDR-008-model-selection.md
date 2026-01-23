# RDR-008: Model Selection Strategy

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata
- **Date**: 2025-01-23
- **Status**: Final
- **Type**: Architecture
- **Priority**: Medium
- **Related Issues**: N/A (foundational decision)
- **Related Tests**: Meta-agent tests, fallback logic tests

## Problem Statement

Paid must select appropriate LLM models for each task. Different tasks benefit from different models:

- **Complex reasoning** (architecture, planning): Needs most capable model
- **Simple edits** (typo fixes, small changes): Cheaper model sufficient
- **Cost-constrained projects**: Must respect budget limits
- **Specialized tasks** (code review, security): May need specific models

Requirements:
- Intelligent model selection based on task characteristics
- Respect project budget constraints
- Fall back gracefully when primary selection fails
- Log selection decisions for analysis
- Support model preferences/exclusions per project

## Context

### Background

The "Bitter Lesson" principle means model selection should be data-driven, not hardcoded. As models improve and new ones emerge, selection criteria should adapt based on measured performance.

Today's expensive model is tomorrow's commodity. Selection logic must evolve without code changes.

### Technical Environment

- Model registry via ruby-llm gem
- Per-project cost tracking and budgets
- Historical performance data available
- LLM-based meta-agent capability

## Research Findings

### Investigation Process

1. Analyzed model capabilities via ruby-llm registry
2. Evaluated meta-agent approaches vs rules-based
3. Designed fallback hierarchy
4. Reviewed cost-quality tradeoffs
5. Studied historical model selection patterns

### Key Discoveries

**Model Registry (ruby-llm):**

ruby-llm provides model metadata:

```ruby
model = RubyLLM.models.find("claude-3-5-sonnet")
model.context_window    # 200_000
model.max_output_tokens # 8192
model.supports_vision?  # true
model.supports_tools?   # true
model.input_cost_per_1k # 0.003
model.output_cost_per_1k # 0.015
```

**Task Complexity Signals:**

Indicators that suggest model capability needed:
- Issue description length and complexity
- Number of files likely involved (from repo analysis)
- Keywords suggesting architecture/planning
- Historical success rates for similar issues
- Explicit labels (e.g., `complex`, `simple`)

**Meta-Agent Approach:**

Use an LLM to select the model:

```ruby
prompt = <<~PROMPT
  Select the best model for this task.

  Task: #{issue.title}
  Description: #{issue.body}
  Repository: #{project.github_repo}
  Primary Language: #{project.primary_language}
  Budget Remaining: $#{budget.remaining_cents / 100.0}

  Available models:
  #{available_models.map { |m| "- #{m.id}: #{m.description}, $#{m.cost_per_1k}/1K" }.join("\n")}

  Consider:
  - Task complexity and reasoning requirements
  - Budget constraints
  - Model capabilities (vision, tools, context size)

  Respond with JSON: {"model": "model-id", "reasoning": "..."}
PROMPT
```

**Rules-Based Fallback:**

When meta-agent fails or is disabled:

```ruby
def select_by_rules(task, budget)
  # 1. Budget constraint
  affordable = models.select { |m| estimated_cost(m, task) <= budget.remaining }
  return default_model if affordable.empty?

  # 2. Complexity heuristic
  if high_complexity?(task)
    return affordable.max_by(&:capability_score)
  end

  # 3. Similar past success
  if past_success = find_similar_success(task)
    return past_success.model if affordable.include?(past_success.model)
  end

  # 4. Default to cost-effective capable model
  affordable.min_by { |m| m.cost_per_1k / m.capability_score }
end
```

**Model Performance History:**

Track model effectiveness per task type:

```sql
SELECT
  model_id,
  task_category,
  COUNT(*) as total_runs,
  AVG(quality_score) as avg_quality,
  AVG(cost_cents) as avg_cost
FROM agent_runs
JOIN quality_metrics ON ...
GROUP BY model_id, task_category;
```

## Proposed Solution

### Approach

Implement **hybrid model selection**:

1. **Primary**: LLM-based meta-agent for intelligent selection
2. **Fallback**: Rules-based selection when meta-agent fails or is too expensive
3. **Override**: Per-project preferences respected
4. **Logging**: All decisions logged for analysis and evolution

### Technical Design

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      MODEL SELECTION ARCHITECTURE                            │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                         INPUT CONTEXT                                    ││
│  │                                                                          ││
│  │  • Task details (issue title, body, labels)                             ││
│  │  • Project context (language, framework, size)                          ││
│  │  • Budget constraints (remaining budget, per-run limit)                 ││
│  │  • Historical data (past similar tasks)                                 ││
│  │  • Overrides (project model preferences)                                ││
│  │                                                                          ││
│  └────────────────────────────────┬────────────────────────────────────────┘│
│                                   │                                          │
│                                   ▼                                          │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                      PROJECT OVERRIDES                                   ││
│  │                                                                          ││
│  │  Check for:                                                             ││
│  │  • Required model (must use X)                                          ││
│  │  • Excluded models (never use Y)                                        ││
│  │  • Preferred models (prefer X over Y)                                   ││
│  │                                                                          ││
│  └────────────────────────────────┬────────────────────────────────────────┘│
│                                   │                                          │
│           ┌───────────────────────┼───────────────────────┐                 │
│           │                       │                       │                 │
│           ▼                       │                       ▼                 │
│  ┌─────────────────┐              │              ┌─────────────────┐        │
│  │  META-AGENT     │              │              │  RULES-BASED    │        │
│  │  (Primary)      │              │              │  (Fallback)     │        │
│  │                 │              │              │                 │        │
│  │ Uses small LLM  │   Fallback   │              │ 1. Budget filter│        │
│  │ to analyze task │──────────────┼─────────────►│ 2. Complexity   │        │
│  │ and select      │   if fails   │              │ 3. History      │        │
│  │ best model      │   or disabled│              │ 4. Cost-quality │        │
│  │                 │              │              │                 │        │
│  └────────┬────────┘              │              └────────┬────────┘        │
│           │                       │                       │                 │
│           └───────────────────────┼───────────────────────┘                 │
│                                   │                                          │
│                                   ▼                                          │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                         SELECTION LOGGING                                ││
│  │                                                                          ││
│  │  model_selections table:                                                ││
│  │  • selected_model_id                                                    ││
│  │  • selector_type (meta_agent | rules | override)                        ││
│  │  • reasoning (meta-agent explanation)                                   ││
│  │  • candidates (all models considered with scores)                       ││
│  │  • constraints (budget, complexity)                                     ││
│  │                                                                          ││
│  └────────────────────────────────┬────────────────────────────────────────┘│
│                                   │                                          │
│                                   ▼                                          │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                         SELECTED MODEL                                   ││
│  │                                                                          ││
│  │  Model ID returned to agent execution workflow                          ││
│  │                                                                          ││
│  └─────────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────┘
```

### Decision Rationale

1. **Meta-agent primary**: LLM reasoning can handle nuanced selection
2. **Rules fallback**: Reliability when meta-agent fails or is disabled
3. **Override support**: Projects can customize behavior
4. **Decision logging**: Enables analysis and improvement
5. **Bitter Lesson aligned**: Selection criteria stored as data, not code

### Implementation Example

```ruby
# app/services/model_selection_service.rb
class ModelSelectionService
  include Servo::Service

  input do
    attribute :task, Dry::Types["any"]
    attribute :project, Dry::Types["any"]
    attribute :task_category, Dry::Types["strict.string"]
  end

  output do
    attribute :model, Dry::Types["any"]
    attribute :reasoning, Dry::Types["strict.string"]
    attribute :selector_type, Dry::Types["strict.string"]
  end

  def call
    # Check for project override
    if override = check_override(project, task_category)
      return success(model: override.model, reasoning: "Project override", selector_type: "override")
    end

    # Get available models within budget
    budget = project.cost_budget
    available = available_models(budget)

    return failure(error: "No affordable models") if available.empty?

    # Try meta-agent selection
    if meta_agent_enabled?(project)
      result = meta_agent_select(task, available, budget)
      if result.success?
        log_selection(result, "meta_agent")
        return result
      end
      # Fall through to rules if meta-agent fails
    end

    # Rules-based fallback
    result = rules_based_select(task, available, budget)
    log_selection(result, "rules")
    result
  end

  private

  def check_override(project, task_category)
    ModelOverride.find_by(
      project_id: project.id,
      override_type: "require",
      task_category: [task_category, nil]
    )
  end

  def available_models(budget)
    Model.active.select do |model|
      # Estimate if affordable for typical task
      estimated = estimate_cost(model, average_tokens: 10_000)
      estimated <= budget&.per_run_limit_cents.to_i || budget.nil?
    end
  end

  def meta_agent_select(task, available, budget)
    prompt = build_selection_prompt(task, available, budget)

    response = RubyLLM.client.chat(
      model: "claude-3-5-haiku",  # Fast, cheap model for meta-agent
      messages: [{ role: "user", content: prompt }],
      response_format: { type: "json_object" }
    )

    parsed = JSON.parse(response.content)
    selected = available.find { |m| m.model_id == parsed["model"] }

    if selected
      success(model: selected, reasoning: parsed["reasoning"], selector_type: "meta_agent")
    else
      failure(error: "Meta-agent selected unavailable model: #{parsed["model"]}")
    end
  rescue => e
    Rails.logger.warn("Meta-agent selection failed: #{e.message}")
    failure(error: e.message)
  end

  def rules_based_select(task, available, budget)
    # Rule 1: High complexity → most capable
    if high_complexity?(task)
      selected = available.max_by(&:capability_score)
      return success(model: selected, reasoning: "High complexity task", selector_type: "rules")
    end

    # Rule 2: Similar past success
    if past = find_similar_success(task, available)
      return success(model: past.model, reasoning: "Similar past success", selector_type: "rules")
    end

    # Rule 3: Best cost-quality ratio
    selected = available.min_by { |m| m.cost_score / m.capability_score }
    success(model: selected, reasoning: "Best cost-quality ratio", selector_type: "rules")
  end

  def high_complexity?(task)
    # Heuristics for complexity
    return true if task.body.to_s.length > 2000
    return true if task.labels.any? { |l| l["name"] =~ /complex|architecture|design/i }
    return true if task.title =~ /refactor|redesign|implement.*system/i
    false
  end

  def find_similar_success(task, available)
    # Find successful past runs with similar characteristics
    AgentRun
      .joins(:quality_metric)
      .where(model: available)
      .where("quality_metrics.quality_score > 0.8")
      .where("issues.title % ?", task.title)  # Trigram similarity
      .order("similarity(issues.title, ?) DESC", task.title)
      .first
  end

  def log_selection(result, selector_type)
    ModelSelection.create!(
      agent_run_id: Current.agent_run_id,
      selected_model_id: result.model.id,
      selector_type: selector_type,
      reasoning: result.reasoning,
      candidates: available.map { |m| { id: m.id, score: m.capability_score } }
    )
  end

  def build_selection_prompt(task, available, budget)
    <<~PROMPT
      Select the best model for this development task.

      ## Task
      Title: #{task.title}
      Description: #{task.body&.truncate(1000)}
      Labels: #{task.labels.map { |l| l["name"] }.join(", ")}

      ## Budget
      Per-run limit: $#{budget&.per_run_limit_cents.to_i / 100.0}
      Daily remaining: $#{budget&.remaining_daily_cents.to_i / 100.0}

      ## Available Models
      #{available.map { |m| model_description(m) }.join("\n")}

      ## Instructions
      Consider:
      1. Task complexity (simple edit vs. complex architecture)
      2. Budget constraints
      3. Model capabilities needed (reasoning, code understanding)

      Respond with JSON:
      {"model": "model-id", "reasoning": "brief explanation"}
    PROMPT
  end

  def model_description(model)
    "- #{model.model_id}: #{model.display_name}, " \
    "$#{model.input_cost_per_1k}/1K in, $#{model.output_cost_per_1k}/1K out, " \
    "context: #{model.context_window}"
  end

  def estimate_cost(model, average_tokens:)
    input_tokens = average_tokens * 0.7
    output_tokens = average_tokens * 0.3
    ((input_tokens / 1000.0 * model.input_cost_per_1k) +
     (output_tokens / 1000.0 * model.output_cost_per_1k) * 100).round
  end
end
```

## Alternatives Considered

### Alternative 1: Static Model Assignment

**Description**: Hardcode model per task category (e.g., always use Claude for planning)

**Pros**:
- Simple implementation
- Predictable costs
- No meta-agent overhead

**Cons**:
- Doesn't adapt to task nuances
- Misses optimization opportunities
- Requires code changes to adjust

**Reason for rejection**: Violates Bitter Lesson. Selection criteria should be data, not code.

### Alternative 2: Pure Rules-Based

**Description**: Only use rules, no meta-agent

**Pros**:
- Deterministic
- No LLM cost for selection
- Easier to debug

**Cons**:
- Rules are limited in nuance
- Hard to capture complex tradeoffs
- Requires manual rule updates

**Reason for rejection**: Rules alone miss nuanced decisions. Meta-agent can reason about complex tradeoffs.

### Alternative 3: Pure Meta-Agent

**Description**: Always use meta-agent, no rules fallback

**Pros**:
- Most intelligent selection
- Adapts to any situation

**Cons**:
- Single point of failure
- Adds latency and cost to every run
- Can make surprising decisions

**Reason for rejection**: Need rules fallback for reliability. Meta-agent can fail or be disabled.

### Alternative 4: User Selects Model

**Description**: Always ask user to select model per task

**Pros**:
- User has full control
- No selection logic needed

**Cons**:
- Friction in automation workflow
- Users may not know optimal model
- Defeats purpose of autonomous agents

**Reason for rejection**: Goal is autonomous operation. User can override if needed, but default should be automatic.

## Trade-offs and Consequences

### Positive Consequences

- **Intelligent selection**: Meta-agent handles nuanced decisions
- **Reliable fallback**: Rules ensure selection always succeeds
- **Customizable**: Project overrides for specific needs
- **Observable**: Decision logging enables analysis
- **Evolvable**: Selection criteria improve over time

### Negative Consequences

- **Meta-agent cost**: Small LLM cost per selection (mitigated: use cheap model)
- **Latency**: Meta-agent adds 1-3 seconds to selection
- **Complexity**: More code than static assignment

### Risks and Mitigations

- **Risk**: Meta-agent makes poor selections
  **Mitigation**: A/B test selection strategies. Monitor quality by selector type. Fall back to rules.

- **Risk**: Meta-agent selection prompt becomes stale
  **Mitigation**: Prompt is data (in prompts table). Evolve via prompt evolution system.

## Implementation Plan

### Prerequisites

- [ ] Model registry populated from ruby-llm
- [ ] Cost budget system in place
- [ ] model_selections table created

### Step-by-Step Implementation

#### Step 1: Create Database Tables

```ruby
# db/migrate/xxx_create_model_selections.rb
class CreateModelSelections < ActiveRecord::Migration[8.0]
  def change
    create_table :model_selections do |t|
      t.references :agent_run, foreign_key: true
      t.references :selected_model, foreign_key: { to_table: :models }
      t.string :selector_type, null: false
      t.text :reasoning
      t.jsonb :candidates
      t.integer :budget_limit_cents
      t.decimal :complexity_score, precision: 4, scale: 2

      t.timestamp :created_at, null: false
    end
  end
end
```

#### Step 2: Implement Selection Service

Create `app/services/model_selection_service.rb` as shown above.

#### Step 3: Create Selection Prompt

```ruby
# db/seeds.rb
Prompt.create!(
  slug: "selection.choose_model",
  name: "Model Selection Prompt",
  category: "selection",
  current_version: PromptVersion.create!(
    version: 1,
    template: <<~TEMPLATE,
      Select the best model for this development task...
      [Full prompt as shown above]
    TEMPLATE
    created_by: "seed"
  )
)
```

#### Step 4: Integrate into Workflow

```ruby
# In AgentExecutionWorkflow
def execute(issue_id)
  issue = activity.fetch_issue(issue_id)
  project = issue.project

  model = activity.select_model(
    task: issue,
    project: project,
    task_category: "coding"
  )

  # Use selected model for agent execution
  result = activity.run_agent(
    model: model.model_id,
    # ...
  )
end
```

### Files to Modify

- `db/migrate/xxx_create_model_selections.rb`
- `app/models/model_selection.rb`
- `app/services/model_selection_service.rb`
- `app/activities/agent_activities.rb` (add select_model)
- `db/seeds.rb` (selection prompt)

### Dependencies

- `ruby-llm` gem for model registry and API calls
- `pg_trgm` extension for similarity search

## Validation

### Testing Approach

1. Unit tests for selection service
2. Integration tests for meta-agent selection
3. A/B tests comparing selection strategies
4. Cost analysis per selection method

### Test Scenarios

1. **Scenario**: High complexity task
   **Expected Result**: Most capable model selected

2. **Scenario**: Budget constraint active
   **Expected Result**: Affordable model selected

3. **Scenario**: Project override exists
   **Expected Result**: Override model used

4. **Scenario**: Meta-agent fails
   **Expected Result**: Falls back to rules

### Performance Validation

- Selection completes in < 5 seconds
- Meta-agent uses cheapest capable model
- Selection cost < 1% of total run cost

### Security Validation

- Selection prompts don't leak sensitive data
- Budget checks prevent cost overruns

## References

### Requirements & Standards

- Paid VISION.md - Bitter Lesson, models as commodities
- Paid ARCHITECTURE.md - Model selection system

### Dependencies

- [ruby-llm](https://github.com/codenamev/ruby-llm) - Model registry
- PostgreSQL pg_trgm extension

### Research Resources

- Model capability benchmarks
- Cost-quality optimization strategies
- Meta-agent patterns

## Notes

- Consider caching selection results for identical tasks
- Monitor meta-agent prompt effectiveness over time
- Future: Multi-armed bandit approach for exploration/exploitation
- Selection prompt should evolve via prompt evolution system
