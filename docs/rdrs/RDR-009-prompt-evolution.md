# RDR-009: Prompt Evolution System

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2025-01-23
- **Status**: Final
- **Type**: Architecture
- **Priority**: High
- **Related Issues**: N/A (foundational decision)
- **Related Tests**: Evolution workflow tests, A/B test analysis tests

## Problem Statement

Prompts are central to Paid's effectiveness. Traditional tools hardcode prompts in source code, making improvement slow and unmeasured. Paid needs:

1. **Version history**: Track all prompt changes
2. **Performance measurement**: Know which prompts work better
3. **A/B testing**: Statistically validate improvements
4. **Automated evolution**: LLM-based prompt improvement
5. **Safe rollback**: Revert to previous versions if needed

The goal is to apply the "Bitter Lesson"—let data and compute improve prompts rather than human intuition alone.

## Context

### Background

Prompt engineering is often ad-hoc:

- Developer changes prompt in code
- Deploy and hope for the best
- No systematic measurement
- Knowledge lost when developers leave

Paid treats prompts as data:

- Stored in database with full history
- Every use logged with prompt version
- Quality metrics tied to specific versions
- A/B testing determines winners
- Evolution agents propose improvements

### Technical Environment

- PostgreSQL for prompt storage
- Temporal for evolution workflows
- Quality metrics from agent runs
- LLM for mutation generation

## Research Findings

### Investigation Process

1. Studied prompt optimization literature
2. Analyzed A/B testing statistical methods
3. Designed evolution agent approach
4. Evaluated quality metric composition
5. Reviewed existing prompt management systems

### Key Discoveries

**Quality Metrics:**

Multiple signals indicate prompt effectiveness:

| Metric | Source | Weight | Interpretation |
|--------|--------|--------|----------------|
| PR merged | GitHub | 30% | Strongest positive signal |
| CI passed | GitHub Actions | 20% | Code quality indicator |
| Human vote | PR comments, UI | 20% | Explicit feedback |
| Iterations | Agent output | 15% | Fewer = better (inverted) |
| Lint clean | CI output | 10% | Code quality |
| Tests pass | CI output | 5% | Functionality |

**Composite Score:**

```ruby
def quality_score(metrics)
  weights = {
    pr_merged: 0.30,
    ci_passed: 0.20,
    human_vote: 0.20,
    iterations_normalized: 0.15,
    lint_clean: 0.10,
    tests_passing: 0.05
  }

  weights.sum do |metric, weight|
    score = case metric
    when :pr_merged then metrics.pr_merged ? 1.0 : 0.0
    when :ci_passed then metrics.ci_passed ? 1.0 : 0.0
    when :human_vote then (metrics.human_vote + 1) / 2.0  # -1..1 → 0..1
    when :iterations_normalized then [1.0 - (metrics.iterations - 1) * 0.1, 0.0].max
    when :lint_clean then metrics.lint_errors.zero? ? 1.0 : 0.0
    when :tests_passing then metrics.test_failures.zero? ? 1.0 : 0.0
    end
    score * weight
  end
end
```

**A/B Testing Statistics:**

Welch's t-test for comparing variants (doesn't assume equal variance):

```ruby
def t_test(control, variant)
  n1, n2 = control.size, variant.size
  m1, m2 = control.mean, variant.mean
  s1, s2 = control.std_dev, variant.std_dev

  se = Math.sqrt((s1**2 / n1) + (s2**2 / n2))
  t = (m1 - m2) / se

  # Welch-Satterthwaite degrees of freedom
  df = ((s1**2/n1 + s2**2/n2)**2) /
       ((s1**4/(n1**2*(n1-1))) + (s2**4/(n2**2*(n2-1))))

  p_value = 2 * (1 - t_distribution_cdf(t.abs, df))
  { t: t, df: df, p_value: p_value }
end
```

Minimum sample size for 80% power, α=0.05:

- Small effect (d=0.2): ~400 per group
- Medium effect (d=0.5): ~65 per group
- Large effect (d=0.8): ~25 per group

For practical purposes, start with 30 samples per variant.

**Evolution Agent Patterns:**

Effective mutations include:

- Adding specificity to vague instructions
- Including examples of desired output
- Clarifying constraints
- Restructuring for clarity
- Addressing observed failure patterns

```
Evolution prompt template:
- Current prompt (the one being evolved)
- Performance analysis (avg quality, common failures)
- Sample failures (low-scoring runs)
- Sample successes (high-scoring runs)
- Instruction to generate 3 improved variants
```

## Proposed Solution

### Approach

Implement a **data-driven prompt evolution system**:

1. **Prompts as entities**: Database records with versioning
2. **Quality tracking**: Metrics per version
3. **A/B testing**: Statistical comparison of variants
4. **Evolution workflow**: Automated mutation and testing
5. **Human oversight**: Review before promotion

### Technical Design

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      PROMPT EVOLUTION SYSTEM                                 │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                         PROMPT LIFECYCLE                                 ││
│  │                                                                          ││
│  │  ┌─────────┐    ┌─────────┐    ┌─────────┐    ┌─────────┐             ││
│  │  │ Create  │───►│  Use    │───►│ Measure │───►│ Evolve  │───┐         ││
│  │  │ Version │    │ in Runs │    │ Quality │    │ Variants│   │         ││
│  │  └─────────┘    └─────────┘    └─────────┘    └─────────┘   │         ││
│  │       ▲                                                       │         ││
│  │       │                                                       │         ││
│  │       └──────────── Promote Winner ◄─────────────────────────┘         ││
│  │                                                                          ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                         DATA MODEL                                       ││
│  │                                                                          ││
│  │  prompts                                                                ││
│  │  ├── id, slug, name, category                                          ││
│  │  └── current_version_id ──────────┐                                    ││
│  │                                    │                                    ││
│  │  prompt_versions                   │                                    ││
│  │  ├── id, prompt_id, version  ◄────┘                                    ││
│  │  ├── template, variables, system_prompt                                ││
│  │  ├── change_notes, created_by                                          ││
│  │  └── parent_version_id (lineage)                                       ││
│  │                                                                          ││
│  │  quality_metrics                                                        ││
│  │  ├── agent_run_id, prompt_version_id                                   ││
│  │  └── quality_score, iterations, ci_passed, human_vote, ...             ││
│  │                                                                          ││
│  │  ab_tests                                                               ││
│  │  ├── prompt_id, name, status                                           ││
│  │  └── winner_variant_id, confidence_level                               ││
│  │                                                                          ││
│  │  ab_test_variants                                                       ││
│  │  ├── ab_test_id, prompt_version_id                                     ││
│  │  └── name, weight, sample_count, avg_quality_score                     ││
│  │                                                                          ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                     EVOLUTION WORKFLOW                                   ││
│  │                                                                          ││
│  │  ┌─────────────┐                                                        ││
│  │  │ Check if    │  Recent evolution? Active A/B test? Good quality?     ││
│  │  │ eligible    │─────────────────────────────────────────────────────►  ││
│  │  └──────┬──────┘                                                  SKIP  ││
│  │         │ eligible                                                       ││
│  │         ▼                                                                ││
│  │  ┌─────────────┐                                                        ││
│  │  │ Analyze     │  Gather quality metrics, identify failure patterns    ││
│  │  │ performance │                                                        ││
│  │  └──────┬──────┘                                                        ││
│  │         │                                                                ││
│  │         ▼                                                                ││
│  │  ┌─────────────┐                                                        ││
│  │  │ Generate    │  LLM creates 3 improved variants                       ││
│  │  │ mutations   │                                                        ││
│  │  └──────┬──────┘                                                        ││
│  │         │                                                                ││
│  │         ▼                                                                ││
│  │  ┌─────────────┐                                                        ││
│  │  │ Create A/B  │  Control (current) + 3 variants                       ││
│  │  │ test        │                                                        ││
│  │  └──────┬──────┘                                                        ││
│  │         │                                                                ││
│  │         ▼                                                                ││
│  │  ┌─────────────┐                                                        ││
│  │  │ Run until   │  Assign runs to variants, collect metrics             ││
│  │  │ significant │                                                        ││
│  │  └──────┬──────┘                                                        ││
│  │         │                                                                ││
│  │         ▼                                                                ││
│  │  ┌─────────────┐                                                        ││
│  │  │ Analyze     │  t-test between control and each variant              ││
│  │  │ results     │                                                        ││
│  │  └──────┬──────┘                                                        ││
│  │         │                                                                ││
│  │    ┌────┴────┐                                                          ││
│  │    ▼         ▼                                                          ││
│  │  Winner    No winner                                                    ││
│  │  found     (keep control)                                               ││
│  │    │                                                                    ││
│  │    ▼                                                                    ││
│  │  Promote (optional human review)                                        ││
│  │                                                                          ││
│  └─────────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────┘
```

### Decision Rationale

1. **Bitter Lesson**: Prompts improve through data, not intuition
2. **Statistical rigor**: A/B testing validates improvements
3. **Automated evolution**: LLM proposes mutations from failure analysis
4. **Safe iteration**: Control group ensures no regression
5. **Full traceability**: Lineage tracking for audit

### Implementation Example

```ruby
# app/workflows/prompt_evolution_workflow.rb
class PromptEvolutionWorkflow
  include Temporalio::Workflow

  def execute(prompt_id)
    prompt = activity.fetch_prompt(prompt_id)

    # Check eligibility
    return { status: :too_recent } if prompt.last_evolved_at&.> 7.days.ago
    return { status: :test_active } if prompt.ab_tests.running.exists?

    # Gather quality data
    runs = activity.sample_agent_runs(
      prompt_id: prompt_id,
      count: 50,
      min_age_hours: 24
    )

    return { status: :insufficient_data } if runs.count < 20

    # Analyze performance
    analysis = activity.analyze_performance(runs)

    # Check if evolution needed
    if analysis[:avg_quality_score] >= 0.85
      return { status: :satisfactory, score: analysis[:avg_quality_score] }
    end

    # Generate mutations
    mutations = activity.generate_mutations(
      prompt: prompt,
      analysis: analysis,
      count: 3
    )

    # Create new versions
    new_versions = mutations.map do |mutation|
      activity.create_prompt_version(
        prompt_id: prompt.id,
        template: mutation[:template],
        change_notes: mutation[:reasoning],
        created_by: "evolution"
      )
    end

    # Create A/B test
    test = activity.create_ab_test(
      prompt_id: prompt.id,
      control_version_id: prompt.current_version_id,
      variant_version_ids: new_versions.map(&:id),
      name: "Evolution #{Date.current}"
    )

    activity.start_ab_test(test.id)
    activity.update_prompt_evolution_timestamp(prompt.id)

    { status: :evolution_started, ab_test_id: test.id }
  end
end

# app/activities/evolution_activities.rb
class EvolutionActivities
  include Temporalio::Activities

  activity
  def analyze_performance(runs)
    metrics = runs.map(&:quality_metric).compact

    failures = metrics.select { |m| m.quality_score < 0.5 }
    successes = metrics.select { |m| m.quality_score > 0.8 }

    {
      avg_quality_score: metrics.sum(&:quality_score) / metrics.size,
      avg_iterations: metrics.sum(&:iterations_to_complete) / metrics.size,
      failure_patterns: identify_failure_patterns(failures),
      failure_samples: runs.select { |r| r.quality_metric&.quality_score.to_f < 0.5 }.take(3),
      success_samples: runs.select { |r| r.quality_metric&.quality_score.to_f > 0.8 }.take(3)
    }
  end

  activity(start_to_close_timeout: 60.seconds)
  def generate_mutations(prompt:, analysis:, count:)
    evolution_prompt = resolve_evolution_prompt(prompt, analysis)

    # Select model for prompt evolution task (creative, medium complexity)
    model = ModelSelectionService.select(
      task_type: :prompt_evolution,
      complexity: :medium
    )

    response = RubyLLM.client.chat(
      model: model,
      messages: [{ role: "user", content: evolution_prompt }],
      response_format: { type: "json_object" }
    )

    JSON.parse(response.content)["mutations"]
  end

  private

  def resolve_evolution_prompt(prompt, analysis)
    template = Prompt.find_by(slug: "evolution.generate_mutation").current_version.template

    PromptResolver.new.resolve(template, {
      prompt: prompt.current_version,
      analysis: analysis
    })
  end

  def identify_failure_patterns(low_quality_metrics)
    patterns = []
    patterns << "High iteration count" if low_quality_metrics.any? { |m| m.iterations_to_complete > 5 }
    patterns << "CI failures" if low_quality_metrics.any? { |m| !m.ci_passed }
    patterns << "Lint errors" if low_quality_metrics.any? { |m| m.lint_errors > 0 }
    patterns << "Negative human feedback" if low_quality_metrics.any? { |m| m.human_vote == -1 }
    patterns
  end
end

# app/services/ab_test_analyzer.rb
class ABTestAnalyzer
  MIN_SAMPLES = 30
  CONFIDENCE_THRESHOLD = 0.95

  def analyze(test)
    variants = test.variants.includes(:quality_metrics)

    # Check minimum samples
    if variants.any? { |v| v.sample_count < MIN_SAMPLES }
      return { status: :insufficient_data }
    end

    # Calculate stats
    stats = variants.map do |variant|
      metrics = variant.quality_metrics
      {
        variant: variant,
        mean: metrics.average(:quality_score),
        std_dev: Math.sqrt(metrics.variance(:quality_score)),
        sample_count: metrics.count
      }
    end

    control = stats.find { |s| s[:variant].name == "control" }

    # Compare each variant to control
    results = stats.reject { |s| s[:variant].name == "control" }.map do |variant_stats|
      t_result = t_test(control, variant_stats)
      {
        variant: variant_stats[:variant],
        mean_diff: variant_stats[:mean] - control[:mean],
        p_value: t_result[:p_value],
        significant: t_result[:p_value] < (1 - CONFIDENCE_THRESHOLD)
      }
    end

    # Determine winner
    significant_improvements = results.select { |r| r[:significant] && r[:mean_diff] > 0 }

    if significant_improvements.any?
      winner = significant_improvements.max_by { |r| r[:mean_diff] }
      {
        status: :winner_found,
        winner: winner[:variant],
        confidence: 1 - winner[:p_value],
        improvement: winner[:mean_diff]
      }
    elsif results.all? { |r| r[:significant] && r[:mean_diff] < 0 }
      { status: :control_wins, confidence: results.map { |r| 1 - r[:p_value] }.min }
    else
      { status: :no_significant_difference }
    end
  end

  private

  def t_test(group1, group2)
    n1, n2 = group1[:sample_count], group2[:sample_count]
    m1, m2 = group1[:mean], group2[:mean]
    s1, s2 = group1[:std_dev], group2[:std_dev]

    se = Math.sqrt((s1**2 / n1) + (s2**2 / n2))
    t = (m1 - m2) / se

    df = ((s1**2/n1 + s2**2/n2)**2) /
         ((s1**4/(n1**2*(n1-1))) + (s2**4/(n2**2*(n2-1))))

    p_value = 2 * Distribution::T.q_value(t.abs, df.floor)
    { t: t, df: df, p_value: p_value }
  end
end
```

## Alternatives Considered

### Alternative 1: Manual Prompt Editing Only

**Description**: No automated evolution; humans edit prompts based on observation

**Pros**:

- Simple implementation
- Human judgment for changes
- No LLM cost for evolution

**Cons**:

- No systematic measurement
- Changes untested before deployment
- Knowledge lost when people leave
- Doesn't scale

**Reason for rejection**: Violates Bitter Lesson. Human intuition is valuable but should be augmented by data.

### Alternative 2: Reinforcement Learning

**Description**: Train a model to optimize prompts directly

**Pros**:

- Potentially optimal prompts
- Learns from all data

**Cons**:

- Requires significant data
- Complex to implement
- Hard to interpret
- Prompt space is vast

**Reason for rejection**: Too complex for initial implementation. LLM-based evolution is simpler and interpretable.

### Alternative 3: Genetic Algorithms

**Description**: Use genetic programming to evolve prompts

**Pros**:

- Explores large space
- No LLM cost for mutation

**Cons**:

- Random mutations often nonsensical
- Requires many generations
- Hard to incorporate semantic understanding

**Reason for rejection**: LLM mutations are more semantically meaningful than random genetic operations.

### Alternative 4: Bayesian Optimization

**Description**: Use Bayesian optimization to tune prompt parameters

**Pros**:

- Sample-efficient optimization
- Handles continuous parameters

**Cons**:

- Prompts aren't continuous parameters
- Requires careful parameterization
- Complex implementation

**Reason for rejection**: Prompts are text, not parameters. LLM-based approach handles text naturally.

## Trade-offs and Consequences

### Positive Consequences

- **Continuous improvement**: Prompts get better over time
- **Statistical validation**: Changes proven to help before deployment
- **Failure analysis**: Evolution targets specific failure modes
- **Safe experimentation**: A/B tests protect against regression
- **Knowledge preservation**: All changes documented with reasoning

### Negative Consequences

- **Evolution cost**: LLM calls for mutation generation
- **Time to significance**: A/B tests require weeks for results
- **Complexity**: Additional system to maintain
- **Potential drift**: Evolved prompts may diverge from intent

### Risks and Mitigations

- **Risk**: Evolution produces prompts that work in metrics but have subtle problems
  **Mitigation**: Optional human review before promotion. Monitor for regression.

- **Risk**: A/B tests never reach significance
  **Mitigation**: Extend test duration. Increase traffic to variants. Accept inconclusive results.

- **Risk**: Evolution prompt itself is suboptimal
  **Mitigation**: Evolution prompt is in prompts table and can itself be evolved (meta-evolution).

## Implementation Plan

### Prerequisites

- [ ] Prompts and prompt_versions tables created
- [ ] Quality metrics collection working
- [ ] A/B test infrastructure in place
- [ ] Temporal workflow system ready

### Step-by-Step Implementation

#### Step 1: Create A/B Test Tables

```ruby
class CreateABTests < ActiveRecord::Migration[8.0]
  def change
    create_table :ab_tests do |t|
      t.references :prompt, null: false, foreign_key: true
      t.string :name, null: false
      t.string :status, default: 'draft'
      t.integer :traffic_percentage, default: 100
      t.integer :min_sample_size, default: 30
      t.references :winner_variant
      t.decimal :confidence_level, precision: 4, scale: 2

      t.timestamps
    end

    create_table :ab_test_variants do |t|
      t.references :ab_test, null: false, foreign_key: true
      t.references :prompt_version, null: false, foreign_key: true
      t.string :name, null: false
      t.integer :weight, default: 50
      t.integer :sample_count, default: 0
      t.decimal :avg_quality_score, precision: 4, scale: 2

      t.timestamps
    end
  end
end
```

#### Step 2: Create Evolution Prompt

```ruby
# db/seeds.rb
Prompt.create!(
  slug: "evolution.generate_mutation",
  name: "Prompt Mutation Generator",
  category: "evolution",
  current_version: PromptVersion.create!(
    version: 1,
    template: <<~TEMPLATE,
      You are a prompt engineer analyzing and improving prompts.

      ## Current Prompt
      {{prompt.template}}

      ## Performance Analysis
      Average quality score: {{analysis.avg_quality_score}}
      Average iterations: {{analysis.avg_iterations}}
      Common failure patterns: {{analysis.failure_patterns}}

      ## Sample Failures
      {{analysis.failure_samples}}

      ## Sample Successes
      {{analysis.success_samples}}

      ## Task
      Generate 3 improved versions addressing the failure patterns.

      Output JSON:
      {
        "mutations": [
          {"template": "...", "reasoning": "..."}
        ]
      }
    TEMPLATE
    created_by: "seed"
  )
)
```

#### Step 3: Implement Workflow and Activities

Create files as shown in implementation example.

#### Step 4: Schedule Evolution Job

```ruby
# config/initializers/good_job.rb
Rails.application.configure do
  config.good_job.enable_cron = true
  config.good_job.cron = {
    prompt_evolution: {
      cron: "0 2 * * *",
      class: "PromptEvolutionJob"
    }
  }
end
```

### Files to Create

- `db/migrate/xxx_create_ab_tests.rb`
- `app/models/ab_test.rb`
- `app/models/ab_test_variant.rb`
- `app/workflows/prompt_evolution_workflow.rb`
- `app/activities/evolution_activities.rb`
- `app/services/ab_test_analyzer.rb`
- `app/services/ab_test_assigner.rb`
- `app/jobs/prompt_evolution_job.rb`

### Dependencies

- `distribution` gem for t-test calculations
- Temporal for workflow execution
- ruby-llm for mutation generation

## Validation

### Testing Approach

1. Unit tests for analyzer and assigner
2. Workflow tests for evolution flow
3. Integration tests for A/B assignment
4. Statistical validation tests

### Test Scenarios

1. **Scenario**: Prompt quality below threshold
   **Expected Result**: Evolution workflow triggers, creates A/B test

2. **Scenario**: Variant significantly better than control
   **Expected Result**: Analyzer reports winner with confidence level

3. **Scenario**: Insufficient samples
   **Expected Result**: Analysis returns insufficient_data status

4. **Scenario**: No significant difference
   **Expected Result**: Control retained, test marked complete

### Performance Validation

- Evolution workflow completes in < 5 minutes
- A/B assignment adds < 5ms to prompt resolution
- Analysis completes in < 1 second

### Security Validation

- Evolution prompts don't leak sensitive data
- A/B test data isolated per account

## References

### Requirements & Standards

- Paid PROMPT_EVOLUTION.md - Full system design
- [A/B Testing Statistics](https://www.evanmiller.org/ab-testing/)

### Dependencies

- [distribution gem](https://github.com/SciRuby/distribution) - Statistical functions
- Temporal for workflows
- ruby-llm for LLM calls

### Research Resources

- Prompt optimization papers
- A/B testing best practices
- Statistical significance calculations

## Notes

- Consider multi-armed bandit for faster convergence
- Monitor for prompt drift over many evolution cycles
- Human review gate can be enabled per-prompt
- Evolution prompt itself should be evolvable (meta-evolution)
