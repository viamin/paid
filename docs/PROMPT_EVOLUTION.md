# Paid Prompt Evolution System

This document describes how Paid treats prompts as data, versions them, tests variations through A/B testing, and evolves them automatically based on measured performance.

## Philosophy

> "Configuration is ephemeral, but data endures."

Traditional AI tools hardcode prompts in source code. When prompts need improvement, developers edit code, deploy, and hope for the best. This approach has several problems:

1. **No history**: Previous prompt versions are lost to git history
2. **No measurement**: No systematic way to know if changes helped
3. **No learning**: Each improvement starts from scratch
4. **No adaptation**: Same prompt for all projects and contexts

Paid treats prompts differently:

- **Prompts are database entities** with full version history
- **Every agent run logs** which prompt version was used
- **Quality metrics** are tied to prompt versions
- **A/B testing** determines which versions perform better
- **Evolution agents** propose improvements based on data

---

## Prompt Structure

### Anatomy of a Prompt

```yaml
# Example prompt entity in Paid
slug: "coding.implement_issue"
name: "Issue Implementation Prompt"
category: "coding"
project_id: null  # Global prompt

current_version:
  version: 7
  template: |
    You are implementing a GitHub issue for a software project.

    ## Issue Details
    Title: {{issue_title}}
    Description: {{issue_body}}

    ## Project Context
    Repository: {{project_repo}}
    Language: {{project_language}}

    ## Style Guide
    {{style_guide}}

    ## Instructions
    1. Analyze the issue requirements carefully
    2. Implement the minimum viable solution
    3. Write tests for your changes
    4. Ensure all existing tests pass
    5. Follow the project's coding conventions

    ## Constraints
    - Do not modify unrelated code
    - Do not add features not requested
    - Keep changes focused and reviewable

  variables:
    - issue_title
    - issue_body
    - project_repo
    - project_language
    - style_guide

  system_prompt: |
    You are an expert software developer. You write clean, maintainable code
    and follow best practices for the technologies you use.
```

### Variable Resolution

Variables in templates are resolved at runtime:

```ruby
# app/services/prompts/resolve.rb
class Prompts::Resolve
  def resolve(prompt_version, context)
    template = prompt_version.template

    prompt_version.variables.each do |key|
      value = context[key.to_sym] || context[key]
      template = template.gsub("{{#{key}}}", value.to_s)
    end

    template
  end
end

# app/services/prompts/render.rb
class Prompts::Render
  def render(slug, context)
    prompt = Prompt.active.find_by!(slug: slug)
    version = prompt.current_version
    Prompts::Resolve.new.resolve(version, context)
  end
end
```

### Prompt Categories

| Category | Purpose | Examples |
|----------|---------|----------|
| `planning` | Feature decomposition, task planning | `planning.feature_decomposition`, `planning.estimate_complexity` |
| `coding` | Implementation, bug fixes | `coding.implement_issue`, `coding.fix_bug` |
| `review` | Code review, PR analysis | `review.pr_review`, `review.security_audit` |
| `testing` | Test generation, test analysis | `testing.generate_tests`, `testing.analyze_coverage` |

---

## Version Management

### Creating Versions

Versions are immutable. Every change creates a new version:

```ruby
# Prompt#create_version! always auto-promotes the new version
class Prompt
  def create_version!(template:, change_notes:, created_by:)
    new_version = versions.create!(
      version: (current_version&.version || 0) + 1,
      template: template,
      variables: extract_variables(template),
      system_prompt: current_version&.system_prompt,
      change_notes: change_notes,
      created_by: created_by,
      parent_version_id: current_version&.id
    )

    update!(current_version: new_version)

    new_version
  end

  # create_pending_version! skips promotion — use for A/B test variants
  def create_pending_version!(template:, change_notes:, created_by:)
    versions.create!(
      version: (current_version&.version || 0) + 1,
      template: template,
      variables: extract_variables(template),
      system_prompt: current_version&.system_prompt,
      change_notes: change_notes,
      created_by: created_by,
      parent_version_id: current_version&.id
    )
  end

  private

  def extract_variables(template)
    template.scan(/\{\{(\w+)\}\}/).flatten.uniq
  end
end
```

### Version Lineage

Every version tracks its parent, enabling lineage analysis:

```
v1 (human) ──► v2 (human) ──► v3 (evolution)
                    │
                    └──► v4 (evolution) ──► v5 (evolution)
                              │
                              └──► v6 (A/B winner, promoted)
```

This lineage helps understand:

- Which evolutionary paths lead to improvements
- What human edits were made and why
- How prompts diverge and converge

---

## Quality Metrics

### Automated Metrics

Collected for every agent run:

| Metric | Measurement | Good Value |
|--------|-------------|------------|
| `iterations_to_complete` | Number of agent iterations | Lower is better |
| `ci_passed` | Did CI pass on first try? | True |
| `lint_errors` | Linting errors in output | 0 |
| `test_failures` | Test failures in output | 0 |
| `code_complexity_delta` | Change in cyclomatic complexity | Near 0 |
| `lines_changed` | LOC added/removed | Proportional to task |

### Human Feedback

Collected from GitHub interactions:

| Signal | Source | Interpretation |
|--------|--------|----------------|
| Thumbs up | PR comment with 👍 or "+1" | Positive |
| Thumbs down | PR comment with 👎 or "-1" | Negative |
| Merge | PR merged | Strong positive |
| Changes requested | PR review requesting changes | Negative |
| Close without merge | PR closed | Strong negative |

### Composite Quality Score

```ruby
class QualityMetric
  SCORE_WEIGHTS = {
    pr_created: 0.25,
    ci_passed: 0.15,
    pr_merged: 0.25,
    iterations: 0.10,
    lint_clean: 0.05,
    tests_pass: 0.05,
    review_comment_count: 0.05,
    agent_rerun_count: 0.10
  }.freeze

  GOAL_WEIGHTS = {
    create_issue: { pr_merged: 0.40, ci_passed: 0.20, tests_pass: 0.20, lint_clean: 0.10, iterations: 0.10 },
    review: { review_comment_count: 0.40, agent_rerun_count: 0.30, pr_merged: 0.15, iterations: 0.15 },
    enhance_issue: { pr_created: 0.30, pr_merged: 0.25, ci_passed: 0.15, tests_pass: 0.15, lint_clean: 0.15 }
  }.freeze

  def composite_score(goal: nil)
    weights = GOAL_WEIGHTS.fetch(goal, SCORE_WEIGHTS)
    weights.sum { |metric, weight| normalized_value(metric) * weight }
  end

  private

  def normalized_value(metric)
    case metric
    when :iterations, :agent_rerun_count, :review_comment_count
      raw = send(metric) || 0
      [1.0 - (raw * 0.1), 0.0].max
    else
      send(metric) ? 1.0 : 0.0
    end
  end
end
```

---

## A/B Testing

### Test Setup

```ruby
class AbTests::Create
  def create_test(prompt:, control_version:, variant_versions:, name:)
    test = ABTest.create!(
      prompt: prompt,
      name: name,
      status: :draft,
      min_sample_size: 30
    )

    test.variants.create!(
      prompt_version: control_version,
      name: "control",
      weight: 50
    )

    variant_versions.each_with_index do |version, i|
      test.variants.create!(
        prompt_version: version,
        name: "variant_#{('a'.ord + i).chr}",
        weight: 50 / variant_versions.size
      )
    end

    test
  end

  def start_test(test)
    test.update!(status: :running, started_at: Time.current)
  end
end
```

### Traffic Assignment

When an agent run needs a prompt, the A/B system assigns a variant:

```ruby
class AbTests::Assign
  def assign(prompt, agent_run)
    active_test = prompt.ab_tests.running.first
    return prompt.current_version unless active_test

    # Deterministic assignment based on agent_run_id
    # Ensures same run always gets same variant if retried
    variant = select_variant(active_test, agent_run.id)

    ABTestAssignment.create!(
      ab_test: active_test,
      variant: variant,
      agent_run: agent_run
    )

    variant.prompt_version
  end

  private

  def select_variant(test, seed)
    variants = test.variants.order(:id)
    total_weight = variants.sum(&:weight)

    # Deterministic random based on seed
    random = Random.new(seed).rand(total_weight)

    cumulative = 0
    variants.find do |variant|
      cumulative += variant.weight
      random < cumulative
    end
  end
end
```

### Statistical Analysis

```ruby
class AbTests::Analyze
  # Minimum samples per variant before analysis
  MIN_SAMPLES = 30

  # Confidence level for declaring winner
  CONFIDENCE_THRESHOLD = 0.95

  def analyze(test)
    variants = test.variants.includes(:quality_metrics)

    # Check if we have enough data
    return { status: :insufficient_data } if variants.any? { |v| v.sample_count < MIN_SAMPLES }

    # Calculate statistics for each variant
    stats = variants.map do |variant|
      metrics = variant.quality_metrics
      {
        variant: variant,
        mean: metrics.average(:quality_score),
        std_dev: metrics.std_dev(:quality_score),
        sample_count: metrics.count
      }
    end

    # Perform t-test between control and each variant
    control = stats.find { |s| s[:variant].name == "control" }
    results = stats.reject { |s| s[:variant].name == "control" }.map do |variant_stats|
      p_value = two_sample_t_test(control, variant_stats)
      {
        variant: variant_stats[:variant],
        mean_diff: variant_stats[:mean] - control[:mean],
        p_value: p_value,
        significant: p_value < (1 - CONFIDENCE_THRESHOLD)
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

  def two_sample_t_test(group1, group2)
    # Welch's t-test (doesn't assume equal variance)
    n1, n2 = group1[:sample_count], group2[:sample_count]
    m1, m2 = group1[:mean], group2[:mean]
    s1, s2 = group1[:std_dev], group2[:std_dev]

    se = Math.sqrt((s1**2 / n1) + (s2**2 / n2))
    t = (m1 - m2) / se

    # Approximate degrees of freedom (Welch-Satterthwaite)
    df = ((s1**2/n1 + s2**2/n2)**2) /
         ((s1**4/(n1**2*(n1-1))) + (s2**4/(n2**2*(n2-1))))

    # Two-tailed p-value
    Distribution::T.q_value(t.abs, df.floor) * 2
  end
end
```

### Test Completion

```ruby
class AbTests::PromoteWinner
  def promote(test, analysis)
    case analysis[:status]
    when :winner_found
      winning_version = analysis[:winner].prompt_version
      test.prompt.update!(current_version: winning_version)

      test.update!(
        status: :completed,
        winner_variant: analysis[:winner],
        confidence_level: analysis[:confidence],
        completed_at: Time.current
      )
    when :control_wins
      test.update!(
        status: :completed,
        winner_variant: test.variants.find_by(name: "control"),
        confidence_level: analysis[:confidence],
        completed_at: Time.current
      )
    when :no_significant_difference
      test.update!(status: :completed, completed_at: Time.current)
    end
  end
end

class AbTests::RecordResult
  def record(agent_run, quality_metric)
    assignment = ABTestAssignment.find_by(agent_run: agent_run)
    return unless assignment

    assignment.update!(quality_metric: quality_metric)
  end
end
```

---

## Prompt Evolution

### The Evolution Agent

A specialized LLM-based agent that improves prompts:

```ruby
# app/services/prompt_evolution/mutate.rb
class PromptEvolution::Mutate
  DEFAULT_MODEL = "claude-sonnet-4-6"

  EVOLUTION_PROMPT = <<~PROMPT
    You are a prompt engineer analyzing and improving prompts for an AI-driven
    software development system.

    ## Current Prompt
    {{prompt_template}}

    ## Performance Analysis
    Average quality score: {{avg_quality_score}}
    Average iterations: {{avg_iterations}}
    Common failure patterns:
    {{failure_patterns}}

    ## Sample Failures (low quality runs)
    {{failure_samples}}

    ## Sample Successes (high quality runs)
    {{success_samples}}

    ## Your Task
    Generate 3 improved versions of this prompt that address the identified
    failure patterns while maintaining what works in the successful runs.

    For each mutation, explain:
    1. What problem you're addressing
    2. What change you're making
    3. Why you expect it to help

    Output as JSON:
    {
      "mutations": [
        {
          "template": "...",
          "reasoning": "...",
          "expected_improvement": "..."
        }
      ]
    }
  PROMPT

  def generate_mutations(prompt:, analysis:, mutation_count: 3)
    resolved_prompt = Prompts::Resolve.new.resolve(
      PromptVersion.new(template: EVOLUTION_PROMPT),
      {
        prompt_template: prompt.current_version.template,
        avg_quality_score: analysis.avg_quality_score.to_s,
        avg_iterations: analysis.avg_iterations.to_s,
        failure_patterns: analysis.failure_patterns,
        failure_samples: analysis.failure_samples.map(&:to_s).join("\n"),
        success_samples: analysis.success_samples.map(&:to_s).join("\n")
      }
    )

    response = AgentHarness.send_message(
      model: DEFAULT_MODEL,
      messages: [{ role: "user", content: resolved_prompt }],
      response_format: { type: "json_object" }
    )

    JSON.parse(response.content)["mutations"].map do |mutation|
      PromptMutation.new(
        template: mutation["template"],
        reasoning: mutation["reasoning"],
        expected_improvement: mutation["expected_improvement"]
      )
    end
  end
end
```

### Evolution Workflow

```ruby
class PromptEvolutionWorkflow
  def execute(prompt_id)
    prompt = Prompt.find(prompt_id)

    # Skip if prompt was recently evolved
    return { status: :too_recent } if prompt.last_evolved_at&.> 7.days.ago

    # Skip if active A/B test
    return { status: :test_in_progress } if prompt.ab_tests.running.exists?

    # Gather quality data
    recent_runs = prompt.current_version.agent_runs
      .where("created_at > ?", 30.days.ago)
      .includes(:quality_metric)

    return { status: :insufficient_data } if recent_runs.count < 5

    # Analyze performance
    analysis = analyze_performance(recent_runs)

    # Check if evolution is needed
    if analysis.avg_quality_score >= 0.7
      return { status: :satisfactory, score: analysis.avg_quality_score }
    end

    # Generate mutations
    evolution_agent = PromptEvolution::Mutate.new
    mutations = evolution_agent.generate_mutations(
      prompt: prompt,
      analysis: analysis,
      mutation_count: 3
    )

    new_versions = mutations.map do |mutation|
      prompt.create_pending_version!(
        template: mutation.template,
        change_notes: mutation.reasoning,
        created_by: :evolution
      )
    end

    test = AbTests::Create.new.create_test(
      prompt: prompt,
      control_version: prompt.current_version,
      variant_versions: new_versions,
      name: "Evolution #{Time.current.strftime('%Y-%m-%d')}"
    )

    AbTests::Create.new.start_test(test)

    prompt.update!(last_evolved_at: Time.current)

    { status: :evolution_started, ab_test_id: test.id, mutations: mutations.size }
  end

  private

  def analyze_performance(runs)
    quality_metrics = runs.map(&:quality_metric).compact

    Analysis.new(
      avg_quality_score: quality_metrics.sum(&:quality_score) / quality_metrics.size,
      avg_iterations: quality_metrics.sum(&:iterations_to_complete) / quality_metrics.size,
      failure_patterns: identify_failure_patterns(quality_metrics.select { |m| m.quality_score < 0.5 }),
      failure_samples: runs.select { |r| r.quality_metric&.quality_score.to_f < 0.5 }.take(3),
      success_samples: runs.select { |r| r.quality_metric&.quality_score.to_f > 0.8 }.take(3)
    )
  end

  def identify_failure_patterns(low_quality_metrics)
    patterns = []
    patterns << "High iteration count" if low_quality_metrics.any? { |m| m.iterations_to_complete > 5 }
    patterns << "CI failures" if low_quality_metrics.any? { |m| !m.ci_passed }
    patterns << "Lint errors" if low_quality_metrics.any? { |m| m.lint_errors > 0 }
    patterns.join(", ")
  end
end
```

### Evolution Scheduling

Evolution runs periodically for all prompts:

```ruby
# Scheduled via GoodJob
class PromptEvolutionJob < ApplicationJob
  queue_as :maintenance

  def perform
    Prompt.active.find_each do |prompt|
      # Start evolution workflow via Temporal
      Paid::TemporalClient.instance.start_workflow(
        PromptEvolutionWorkflow,
        prompt.id,
        workflow_id: "evolution-#{prompt.id}-#{Date.current}"
      )
    end
  end
end

# config/initializers/good_job.rb
Rails.application.configure do
  config.good_job.enable_cron = true
  config.good_job.cron = {
    evolution_check: {
      cron: "0 3 * * 1",
      class: "PromptEvolutionJob"
    }
  }
end
```

---

## Human-in-the-Loop

### Manual Prompt Editing

Users can always edit prompts directly:

```ruby
class PromptsController < ApplicationController
  def update
    prompt = Prompt.find(params[:id])

    if params[:promote_immediately]
      new_version = prompt.create_version!(
        template: params[:template],
        change_notes: params[:change_notes],
        created_by: :user
      )
      flash[:notice] = "Prompt updated and promoted"
    else
      new_version = prompt.create_pending_version!(
        template: params[:template],
        change_notes: params[:change_notes],
        created_by: :user
      )
      test = AbTests::Create.new.create_test(
        prompt: prompt,
        control_version: prompt.current_version,
        variant_versions: [new_version],
        name: "Manual edit #{Time.current.strftime('%Y-%m-%d')}"
      )
      AbTests::Create.new.start_test(test)
      flash[:notice] = "A/B test started for your changes"
    end

    redirect_to prompt_path(prompt)
  end
end
```

### Review Evolved Prompts

Optional gate before evolution results are promoted:

```ruby
class ABTestsController < ApplicationController
  def promote
    test = ABTest.find(params[:id])

    winning_version = test.winner_variant.prompt_version
    test.prompt.update!(current_version: winning_version)
    test.update!(review_status: :approved)

    flash[:notice] = "Evolved prompt promoted"
    redirect_to prompt_path(test.prompt)
  end

  def cancel
    test = ABTest.find(params[:id])

    test.update!(status: :rejected, review_status: :rejected)

    flash[:notice] = "Evolution rejected, keeping current prompt"
    redirect_to prompt_path(test.prompt)
  end
end
```

Each A/B test has a `review_status` field (`pending`, `approved`, `rejected`) and a `requires_review` flag. When `requires_review` is true, the evolution workflow pauses after analysis and waits for human approval before promoting any winner.

---

## Prompt Dashboard

### Metrics View

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ Prompt: coding.implement_issue                                               │
│ Current Version: v7 (evolved, 2 weeks ago)                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│ Quality Score (30 days)          Iterations (30 days)                       │
│ ┌───────────────────────┐        ┌───────────────────────┐                  │
│ │    ████████████░░░    │ 0.78   │ █████░░░░░░░░░░░░░░░░ │ 2.3 avg         │
│ └───────────────────────┘        └───────────────────────┘                  │
│                                                                              │
│ Version History                                                             │
│ ┌─────────────────────────────────────────────────────────────────────────┐ │
│ │ v7 (current) │ evolution │ 0.78 quality │ 2024-01-08 │ [View] [Compare]│ │
│ │ v6           │ user      │ 0.71 quality │ 2024-01-01 │ [View] [Compare]│ │
│ │ v5           │ evolution │ 0.69 quality │ 2023-12-15 │ [View] [Compare]│ │
│ └─────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
│ Active A/B Test: None                               [Start New Test]        │
│                                                                              │
│ [Edit Prompt] [View Template] [Evolution History]                           │
└─────────────────────────────────────────────────────────────────────────────┘
```

### A/B Test View

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ A/B Test: Evolution 2024-01-15                                              │
│ Status: Running (14 days, 47 samples)                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│ Variant        │ Samples │ Quality │ Iterations │ CI Pass │ Significance   │
│ ───────────────┼─────────┼─────────┼────────────┼─────────┼──────────────  │
│ control (v7)   │ 25      │ 0.78    │ 2.3        │ 92%     │ baseline       │
│ variant_a (v8) │ 12      │ 0.82    │ 1.9        │ 95%     │ p=0.12 (-)    │
│ variant_b (v9) │ 10      │ 0.75    │ 2.5        │ 88%     │ p=0.34 (-)    │
│                                                                              │
│ ⚠️  Need 30 samples per variant for statistical significance                 │
│                                                                              │
│ [Pause Test] [End Early] [View Details]                                     │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Best Practices

### Prompt Writing Guidelines

1. **Be specific**: Vague instructions lead to inconsistent results
2. **Include examples**: Show the format you expect
3. **State constraints clearly**: What should the agent NOT do?
4. **Reference context**: Use style guides and project conventions
5. **Structure with sections**: Headers help LLMs parse complex prompts

### A/B Testing Guidelines

1. **One change at a time**: Test specific hypotheses
2. **Wait for significance**: Don't end tests early
3. **Consider context**: Different projects may need different prompts
4. **Review evolution**: Human oversight catches weird mutations

### Evolution Guidelines

1. **Start conservative**: Let A/B testing validate before promoting
2. **Review failure patterns**: Understand why before changing
3. **Keep history**: Never delete old versions
4. **Monitor drift**: Evolved prompts can drift from original intent
