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
    Title: {{issue.title}}
    Description: {{issue.body}}

    ## Project Context
    Repository: {{project.github_owner}}/{{project.github_repo}}
    Language: {{project.primary_language}}

    ## Style Guide
    {{style_guide.compressed}}

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
    - issue.title
    - issue.body
    - project.github_owner
    - project.github_repo
    - project.primary_language
    - style_guide.compressed

  system_prompt: |
    You are an expert software developer. You write clean, maintainable code
    and follow best practices for the technologies you use.
```

### Variable Resolution

Variables in templates are resolved at runtime:

```ruby
class PromptResolver
  def resolve(prompt_version, context)
    template = prompt_version.template

    prompt_version.variables.each do |var_path|
      value = dig_value(context, var_path)
      template = template.gsub("{{#{var_path}}}", value.to_s)
    end

    template
  end

  private

  def dig_value(context, path)
    path.split(".").reduce(context) { |obj, key| obj[key.to_sym] || obj[key] }
  end
end
```

### Prompt Categories

| Category | Purpose | Examples |
|----------|---------|----------|
| `planning` | Feature decomposition, task planning | `planning.feature_decomposition`, `planning.estimate_complexity` |
| `coding` | Implementation, bug fixes | `coding.implement_issue`, `coding.fix_bug` |
| `review` | Code review, PR analysis | `review.pr_review`, `review.security_audit` |
| `evolution` | Meta-prompts for evolving other prompts | `evolution.analyze_failures`, `evolution.generate_mutation` |
| `selection` | Model selection reasoning | `selection.choose_model` |

---

## Version Management

### Creating Versions

Versions are immutable. Every change creates a new version:

```ruby
class PromptVersionService
  def create_version(prompt, template:, change_notes:, created_by:)
    current = prompt.current_version

    new_version = prompt.versions.create!(
      version: (current&.version || 0) + 1,
      template: template,
      variables: extract_variables(template),
      system_prompt: current&.system_prompt,  # Inherit unless explicitly changed
      change_notes: change_notes,
      created_by: created_by,
      parent_version_id: current&.id
    )

    # Don't automatically promote - let A/B testing decide
    # prompt.update!(current_version: new_version)

    new_version
  end

  private

  def extract_variables(template)
    template.scan(/\{\{([^}]+)\}\}/).flatten.uniq
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
class QualityScorer
  WEIGHTS = {
    pr_merged: 0.30,          # Strongest signal
    ci_passed: 0.20,
    human_vote: 0.20,
    iterations_normalized: 0.15,  # Inverted: fewer = better
    lint_clean: 0.10,
    tests_passing: 0.05
  }.freeze

  def score(quality_metric)
    scores = {
      pr_merged: quality_metric.pr_merged ? 1.0 : 0.0,
      ci_passed: quality_metric.ci_passed ? 1.0 : 0.0,
      human_vote: normalize_vote(quality_metric.human_vote),
      iterations_normalized: normalize_iterations(quality_metric.iterations_to_complete),
      lint_clean: quality_metric.lint_errors.zero? ? 1.0 : 0.0,
      tests_passing: quality_metric.test_failures.zero? ? 1.0 : 0.0
    }

    WEIGHTS.sum { |metric, weight| scores[metric] * weight }
  end

  private

  def normalize_vote(vote)
    case vote
    when 1 then 1.0
    when 0 then 0.5
    when -1 then 0.0
    else 0.5  # No feedback
    end
  end

  def normalize_iterations(iterations)
    return 0.5 if iterations.nil?
    # 1 iteration = 1.0, 5 iterations = 0.5, 10+ = 0.0
    [1.0 - ((iterations - 1) * 0.1), 0.0].max
  end
end
```

---

## A/B Testing

### Test Setup

```ruby
class ABTestService
  def create_test(prompt:, control_version:, variant_versions:, name:)
    test = ABTest.create!(
      prompt: prompt,
      name: name,
      status: :draft,
      min_sample_size: 30
    )

    # Control variant
    test.variants.create!(
      prompt_version: control_version,
      name: "control",
      weight: 50
    )

    # Test variants
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
class ABTestAssigner
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
class ABTestAnalyzer
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
class ABTestCompleter
  def complete(test, analysis)
    case analysis[:status]
    when :winner_found
      # Promote winning variant to current version
      winning_version = analysis[:winner].prompt_version
      test.prompt.update!(current_version: winning_version)

      test.update!(
        status: :completed,
        winner_variant: analysis[:winner],
        confidence_level: analysis[:confidence],
        completed_at: Time.current
      )
    when :control_wins
      # Keep current version
      test.update!(
        status: :completed,
        winner_variant: test.variants.find_by(name: "control"),
        confidence_level: analysis[:confidence],
        completed_at: Time.current
      )
    when :no_significant_difference
      # Extend test or close without winner
      test.update!(status: :completed, completed_at: Time.current)
    end
  end
end
```

---

## Prompt Evolution

### The Evolution Agent

A specialized LLM-based agent that improves prompts:

```ruby
class PromptEvolutionAgent
  EVOLUTION_PROMPT = <<~PROMPT
    You are a prompt engineer analyzing and improving prompts for an AI-driven
    software development system.

    ## Current Prompt
    {{prompt.template}}

    ## Performance Analysis
    Average quality score: {{analysis.avg_quality_score}}
    Average iterations: {{analysis.avg_iterations}}
    Common failure patterns:
    {{analysis.failure_patterns}}

    ## Sample Failures (low quality runs)
    {{analysis.failure_samples}}

    ## Sample Successes (high quality runs)
    {{analysis.success_samples}}

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
    resolved_prompt = PromptResolver.new.resolve(
      PromptVersion.new(template: EVOLUTION_PROMPT),
      { prompt: prompt.current_version, analysis: analysis }
    )

    # Select model for prompt evolution (creative task, medium complexity)
    model = ModelSelectionService.select(
      task_type: :prompt_evolution,
      complexity: :medium
    )

    response = RubyLLM.client.chat(
      model: model,
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

    return { status: :insufficient_data } if recent_runs.count < 20

    # Analyze performance
    analysis = analyze_performance(recent_runs)

    # Check if evolution is needed
    if analysis.avg_quality_score >= 0.85
      return { status: :satisfactory, score: analysis.avg_quality_score }
    end

    # Generate mutations
    evolution_agent = PromptEvolutionAgent.new
    mutations = evolution_agent.generate_mutations(
      prompt: prompt,
      analysis: analysis,
      mutation_count: 3
    )

    # Create new versions from mutations
    new_versions = mutations.map do |mutation|
      PromptVersionService.new.create_version(
        prompt,
        template: mutation.template,
        change_notes: mutation.reasoning,
        created_by: :evolution
      )
    end

    # Create A/B test
    test = ABTestService.new.create_test(
      prompt: prompt,
      control_version: prompt.current_version,
      variant_versions: new_versions,
      name: "Evolution #{Time.current.strftime('%Y-%m-%d')}"
    )

    ABTestService.new.start_test(test)

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
    patterns << "Negative human feedback" if low_quality_metrics.any? { |m| m.human_vote == -1 }
    patterns.join(", ")
  end
end
```

### Evolution Scheduling

Evolution runs periodically for all prompts:

```ruby
# Scheduled via GoodJob
class PromptEvolutionJob < ApplicationJob
  queue_as :evolution

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
      cron: "0 2 * * *",
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

    new_version = PromptVersionService.new.create_version(
      prompt,
      template: params[:template],
      change_notes: params[:change_notes],
      created_by: :user
    )

    # Option to immediately promote or A/B test
    if params[:promote_immediately]
      prompt.update!(current_version: new_version)
      flash[:notice] = "Prompt updated and promoted"
    else
      test = ABTestService.new.create_test(
        prompt: prompt,
        control_version: prompt.current_version,
        variant_versions: [new_version],
        name: "Manual edit #{Time.current.strftime('%Y-%m-%d')}"
      )
      ABTestService.new.start_test(test)
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
  def approve_winner
    test = ABTest.find(params[:id])

    # Admin manually approves the winner
    winning_version = test.winner_variant.prompt_version
    test.prompt.update!(current_version: winning_version)

    flash[:notice] = "Evolved prompt promoted"
    redirect_to prompt_path(test.prompt)
  end

  def reject_winner
    test = ABTest.find(params[:id])

    # Keep current version, mark test as rejected
    test.update!(status: :rejected)

    flash[:notice] = "Evolution rejected, keeping current prompt"
    redirect_to prompt_path(test.prompt)
  end
end
```

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
