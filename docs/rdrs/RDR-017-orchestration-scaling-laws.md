# RDR-017: Orchestration Scaling Laws

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata
- **Date**: 2025-01-26
- **Status**: Draft
- **Type**: Research
- **Priority**: Low
- **Related Issues**: N/A (foundational research)
- **Related RDRs**: RDR-014 (Learned Orchestration), RDR-015 (End-to-End Optimization)

## Problem Statement

The Bitter Lesson's core insight is that methods which **scale with computation** ultimately win. For LLM training, this manifests as scaling laws: larger models trained on more data perform predictably better.

**Question**: Do similar scaling laws exist for AI agent orchestration?

Specifically:
1. Does success rate improve with more agents per task?
2. Does quality improve with more iterations per agent?
3. Does parallel execution yield better outcomes than serial?
4. At what point do returns diminish?

Without answers, Paid cannot know whether investing compute in more agents, more iterations, or more parallelism will improve outcomes.

## Context

### Background

LLM scaling laws (Kaplan et al., Hoffmann et al.) show:
- Performance improves as power law of model size, data, and compute
- Optimal allocation exists between model size and training data
- Predictable enough to plan training runs

**Hypothesis**: Agent orchestration may have analogous scaling behaviors:
- More agents → better task coverage → higher success rate
- More iterations → more refinement → higher quality
- More parallel exploration → better solutions found

**Counter-hypothesis**: Orchestration may have sharp limits:
- Coordination overhead may dominate beyond some agent count
- Iteration quality may plateau quickly
- Parallelism may introduce conflicts that reduce quality

### Why This Matters

If scaling laws exist:
- **Resource allocation becomes predictable**: Know cost/benefit of more agents
- **Optimization has clear direction**: Scale dimensions that improve outcomes
- **Architecture decisions are informed**: Design for scalable dimensions

If scaling laws don't exist:
- **Different optimization strategy needed**: Focus on efficiency, not scale
- **Ceiling exists**: Know limits of improvement from compute
- **Focus shifts to quality**: Better prompts matter more than more agents

### What We Want to Learn

1. **Agent scaling**: Does N agents perform better than 1? Where's diminishing returns?
2. **Iteration scaling**: Do more agent iterations improve quality?
3. **Parallelism scaling**: Does parallel execution beat sequential?
4. **Context scaling**: Does more context to agents improve outcomes?
5. **Interaction effects**: Do scaling laws change by task type, project, or model?

## Research Findings

### Investigation Areas

1. LLM scaling law literature
2. Multi-agent simulation research
3. Ensemble learning theory
4. Parallel algorithm analysis

### Hypothesized Scaling Behaviors

**Agent Count Scaling:**

```
Success Rate vs Agent Count

1.0 │                    ┌────────────
    │               ┌────┘
    │          ┌────┘
    │     ┌────┘
0.5 │ ────┘
    │
0.0 └─────────────────────────────────
    1    2    3    4    5    6    7+
                Agents

Hypothesis: Logarithmic improvement, diminishing returns after ~4 agents
```

**Iteration Scaling:**

```
Quality Score vs Iterations

1.0 │                         ┌───────
    │                   ┌─────┘
    │             ┌─────┘
    │       ┌─────┘
0.5 │ ──────┘
    │
0.0 └─────────────────────────────────
    1    2    3    4    5    6    7+
              Iterations

Hypothesis: Steep initial improvement, plateau after ~5 iterations
```

**Parallelism Effects:**

```
Time to Completion vs Parallelism

100%│ ─────┐
    │      └───┐
    │          └───┐
    │              └───┐
 50%│                  └───────────
    │
  0%└─────────────────────────────────
    1    2    3    4    5    6    7+
            Parallel Agents

Hypothesis: Near-linear speedup initially, coordination overhead at scale
```

### Potential Scaling Dimensions

| Dimension | Mechanism | Expected Behavior | Measurement |
|-----------|-----------|-------------------|-------------|
| Agent count | Ensemble diversity | Log improvement | Success rate vs count |
| Iterations | Refinement | Plateau | Quality vs iterations |
| Parallelism | Speedup + exploration | Sublinear | Time vs parallel count |
| Context size | Information | Log improvement | Quality vs context tokens |
| Model size | Capability | Power law | Quality vs model size |
| Retry count | Error recovery | Diminishing | Success vs retries |

### Experimental Design Considerations

**Challenge 1: Confounding variables**
- Task difficulty varies
- Projects differ in complexity
- Models have different capabilities

**Mitigation**: Controlled experiments with matched tasks, A/B testing

**Challenge 2: Sample size**
- Each "sample" is an expensive agent run
- Need sufficient data per configuration

**Mitigation**: Phased experiments, start with cheap dimensions

**Challenge 3: Interaction effects**
- Scaling laws may depend on task type
- Project characteristics affect scaling

**Mitigation**: Segment analysis by context

## Proposed Solution

### Approach

Implement **Orchestration Scaling Experiments** as a systematic research program:

1. **Instrumentation**: Track all scaling dimensions in agent runs
2. **Controlled experiments**: A/B tests for specific scaling hypotheses
3. **Analysis pipeline**: Statistical analysis of scaling behaviors
4. **Dynamic allocation**: Use discovered scaling laws to allocate compute

### Technical Design

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    SCALING LAW RESEARCH SYSTEM                               │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                     INSTRUMENTATION                                      ││
│  │                                                                          ││
│  │  scaling_observations                                                    ││
│  │  ├── agent_run_id                                                       ││
│  │  ├── task_complexity (estimated)                                        ││
│  │  ├── project_characteristics                                            ││
│  │  │                                                                       ││
│  │  │  # Scaling dimensions                                                 ││
│  │  ├── agent_count (how many agents worked on this task)                  ││
│  │  ├── total_iterations (sum across all agents)                           ││
│  │  ├── parallelism_level (max concurrent agents)                          ││
│  │  ├── context_tokens (total context provided)                            ││
│  │  ├── model_size_category (small/medium/large)                           ││
│  │  ├── retry_count                                                        ││
│  │  │                                                                       ││
│  │  │  # Outcomes                                                           ││
│  │  ├── success (boolean)                                                  ││
│  │  ├── quality_score                                                      ││
│  │  ├── time_to_complete                                                   ││
│  │  └── total_cost                                                         ││
│  │                                                                          ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                     EXPERIMENTS                                          ││
│  │                                                                          ││
│  │  scaling_experiments                                                     ││
│  │  ├── id, name, hypothesis                                               ││
│  │  ├── dimension_tested (agent_count, iterations, parallelism, etc.)      ││
│  │  ├── values_tested (e.g., [1, 2, 4, 8] for agent count)                ││
│  │  ├── control_value (e.g., 1 agent as baseline)                          ││
│  │  ├── context_filter (which tasks to include)                            ││
│  │  ├── status (running, completed, analyzed)                              ││
│  │  └── results (JSONB: statistical analysis)                              ││
│  │                                                                          ││
│  │  experiment_assignments                                                  ││
│  │  ├── scaling_experiment_id                                              ││
│  │  ├── agent_run_id                                                       ││
│  │  ├── assigned_value (e.g., 4 agents)                                    ││
│  │  └── observed_outcome                                                   ││
│  │                                                                          ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                     ANALYSIS                                             ││
│  │                                                                          ││
│  │  ScalingAnalyzer                                                         ││
│  │  ├── fit_power_law(dimension, outcomes) → exponent, R²                  ││
│  │  ├── fit_logarithmic(dimension, outcomes) → coefficient, R²             ││
│  │  ├── find_diminishing_returns_point(dimension, outcomes) → threshold    ││
│  │  ├── compare_scaling_by_context(dimension, contexts) → differences      ││
│  │  └── optimal_allocation(budget, dimensions) → allocation                ││
│  │                                                                          ││
│  │  Outputs:                                                                ││
│  │  ├── Scaling exponents per dimension                                    ││
│  │  ├── Diminishing returns thresholds                                     ││
│  │  ├── Context-specific scaling behaviors                                 ││
│  │  └── Optimal compute allocation recommendations                         ││
│  │                                                                          ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                     DYNAMIC ALLOCATION                                   ││
│  │                                                                          ││
│  │  ScalingBasedAllocator                                                   ││
│  │  ├── Given: task, budget, discovered scaling laws                       ││
│  │  ├── Output: optimal (agent_count, max_iterations, parallelism)         ││
│  │  │                                                                       ││
│  │  │  Example allocation logic:                                            ││
│  │  │  - If agent scaling exponent > iteration scaling exponent:           ││
│  │  │    → Allocate more agents, fewer iterations                          ││
│  │  │  - If parallelism shows linear speedup below threshold:              ││
│  │  │    → Use full parallelism up to threshold                            ││
│  │  │  - If context scaling is strong:                                     ││
│  │  │    → Invest in gathering more context                                ││
│  │  │                                                                       ││
│  │  └── Updates as more scaling data collected                             ││
│  │                                                                          ││
│  └─────────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────┘
```

### Experiment Protocol

```ruby
# app/services/scaling_experiment_service.rb
class ScalingExperimentService
  # Define experiment for agent count scaling
  AGENT_COUNT_EXPERIMENT = {
    name: "Agent Count Scaling",
    hypothesis: "Success rate improves logarithmically with agent count",
    dimension: :agent_count,
    values: [1, 2, 3, 4, 6, 8],
    control: 1,
    min_samples_per_value: 30,
    context_filter: { min_complexity: :medium }  # Skip trivial tasks
  }

  def create_experiment(config)
    ScalingExperiment.create!(
      name: config[:name],
      hypothesis: config[:hypothesis],
      dimension_tested: config[:dimension],
      values_tested: config[:values],
      control_value: config[:control],
      context_filter: config[:context_filter],
      status: :running
    )
  end

  def assign_to_experiment(experiment:, task:)
    return nil unless experiment.matches_context?(task)
    return nil if experiment.has_sufficient_samples?

    # Assign to value with fewest samples (balanced design)
    value = experiment.values_tested.min_by do |v|
      experiment.sample_count_for(v)
    end

    ExperimentAssignment.create!(
      scaling_experiment: experiment,
      assigned_value: value
    )

    value
  end
end

# app/services/scaling_analyzer.rb
class ScalingAnalyzer
  def analyze_experiment(experiment)
    data = experiment.assignments.includes(:agent_run).map do |a|
      {
        x: a.assigned_value,
        y: a.agent_run.quality_metric.quality_score,
        success: a.agent_run.pr_merged?
      }
    end

    {
      power_law_fit: fit_power_law(data),
      log_fit: fit_logarithmic(data),
      linear_fit: fit_linear(data),
      diminishing_returns: find_knee_point(data),
      success_rate_by_value: success_rate_by_value(data),
      recommended_value: recommend_value(data, experiment.dimension_tested)
    }
  end

  def fit_power_law(data)
    # y = a * x^b
    # Log transform: log(y) = log(a) + b*log(x)

    log_x = data.map { |d| Math.log(d[:x]) }
    log_y = data.map { |d| Math.log([d[:y], 0.001].max) }

    slope, intercept, r_squared = linear_regression(log_x, log_y)

    {
      exponent: slope,
      coefficient: Math.exp(intercept),
      r_squared: r_squared,
      interpretation: interpret_exponent(slope)
    }
  end

  def fit_logarithmic(data)
    # y = a * log(x) + b

    log_x = data.map { |d| Math.log(d[:x]) }
    y = data.map { |d| d[:y] }

    slope, intercept, r_squared = linear_regression(log_x, y)

    {
      coefficient: slope,
      intercept: intercept,
      r_squared: r_squared
    }
  end

  def find_knee_point(data)
    # Find where marginal improvement drops below threshold

    values = data.map { |d| d[:x] }.uniq.sort
    means = values.map do |v|
      points = data.select { |d| d[:x] == v }
      points.sum { |d| d[:y] } / points.size
    end

    # Calculate marginal improvements
    marginals = values.zip(means).each_cons(2).map do |(v1, m1), (v2, m2)|
      {
        from: v1,
        to: v2,
        improvement: m2 - m1,
        relative_improvement: (m2 - m1) / (v2 - v1)
      }
    end

    # Find first point where improvement drops below 5%
    knee = marginals.find { |m| m[:relative_improvement] < 0.05 }

    knee ? knee[:from] : values.last
  end

  private

  def interpret_exponent(exp)
    case exp
    when 0.9..1.1 then "Linear scaling"
    when 0.5..0.9 then "Sublinear scaling (good efficiency)"
    when 0.1..0.5 then "Logarithmic scaling (diminishing returns)"
    when -Float::INFINITY..0.1 then "Minimal scaling (ceiling reached)"
    else "Superlinear scaling (unusual)"
    end
  end
end
```

### Applying Discovered Laws

```ruby
# app/services/scaling_based_allocator.rb
class ScalingBasedAllocator
  def allocate(task:, budget:)
    context = encode_context(task)
    laws = load_scaling_laws(context)

    # Optimize allocation given budget and scaling behaviors

    allocation = optimize_allocation(
      budget: budget,
      dimensions: {
        agent_count: {
          cost_per_unit: laws[:agent_cost],
          scaling_exponent: laws[:agent_scaling_exponent],
          max_value: 8
        },
        iterations: {
          cost_per_unit: laws[:iteration_cost],
          scaling_exponent: laws[:iteration_scaling_exponent],
          max_value: 10
        },
        context_tokens: {
          cost_per_unit: laws[:context_cost_per_1k],
          scaling_exponent: laws[:context_scaling_exponent],
          max_value: 100_000
        }
      }
    )

    {
      agent_count: allocation[:agent_count],
      max_iterations: allocation[:iterations],
      context_budget: allocation[:context_tokens],
      expected_quality: predict_quality(allocation, laws),
      expected_cost: predict_cost(allocation, laws)
    }
  end

  private

  def optimize_allocation(budget:, dimensions:)
    # Lagrange multiplier optimization
    # Maximize: sum(exponent_i * log(value_i))
    # Subject to: sum(cost_i * value_i) <= budget

    # Analytical solution for log-utility:
    # value_i = (exponent_i * budget) / (cost_i * sum(exponents))

    total_exponent = dimensions.values.sum { |d| d[:scaling_exponent] }

    allocation = {}
    dimensions.each do |dim, config|
      optimal = (config[:scaling_exponent] * budget) /
                (config[:cost_per_unit] * total_exponent)

      allocation[dim] = [[optimal.round, 1].max, config[:max_value]].min
    end

    allocation
  end
end
```

### Decision Rationale

1. **Empirical foundation**: Let data reveal scaling behaviors
2. **Controlled experiments**: Isolate effects of each dimension
3. **Actionable outputs**: Scaling laws inform resource allocation
4. **Continuous refinement**: Laws update as more data collected
5. **Context-aware**: Different scaling may exist for different tasks

## Alternatives Considered

### Alternative 1: Assume LLM Scaling Laws Apply

**Description**: Assume agent orchestration follows same scaling as LLM training

**Pros**:
- No experiments needed
- Can use existing research

**Cons**:
- Orchestration is fundamentally different from training
- No empirical validation
- May make wrong assumptions

**Reason for rejection**: Orchestration may have different scaling behaviors. Need empirical data.

### Alternative 2: No Scaling Research

**Description**: Continue with fixed resource allocation

**Pros**:
- Simple
- No research overhead

**Cons**:
- May waste compute on wrong dimensions
- Can't predict cost/benefit tradeoffs
- Miss optimization opportunities

**Reason for rejection**: Understanding scaling is essential for efficient operation at scale.

### Alternative 3: User-Specified Allocation

**Description**: Let users choose agent count, iterations, etc.

**Pros**:
- Users have domain knowledge
- No automated optimization needed

**Cons**:
- Most users don't know optimal settings
- Inconsistent across users
- No improvement over time

**Reason for rejection**: System should learn optimal allocation, not burden users.

## Trade-offs and Consequences

### Positive Consequences

- **Informed resource allocation**: Know where compute helps most
- **Predictable costs**: Model cost/quality tradeoffs
- **Optimization direction**: Clear targets for improvement
- **Scaling roadmap**: Know how system improves with scale

### Negative Consequences

- **Research overhead**: Experiments consume resources
- **Complexity**: Another system to maintain
- **Uncertainty**: Laws may not be stable or universal
- **Time to results**: Needs substantial data before conclusions

### Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Experiments waste resources | Start with cheap dimensions; limit experiment budget |
| Laws don't generalize | Segment by context; update continuously |
| Over-reliance on laws | Keep human override capability |
| Laws change over time | Continuous re-estimation; detect distribution shift |

## Implementation Plan

### Prerequisites

- [ ] Multi-agent orchestration working
- [ ] Quality metrics collection comprehensive
- [ ] Sufficient task diversity for experiments
- [ ] Compute budget for experiments

### Phase 1: Instrumentation

1. Create `scaling_observations` table
2. Instrument workflow to record scaling dimensions
3. Build baseline dataset from existing runs
4. Exploratory analysis of existing data

### Phase 2: Controlled Experiments

1. Create experiment framework
2. Run agent count experiment (highest impact hypothesis)
3. Run iteration count experiment
4. Analyze results and publish internal findings

### Phase 3: Dynamic Allocation

1. Implement scaling-based allocator
2. A/B test against fixed allocation
3. Integrate into production workflow
4. Continuous monitoring and refinement

### Files to Create

- `db/migrate/xxx_create_scaling_observations.rb`
- `db/migrate/xxx_create_scaling_experiments.rb`
- `app/models/scaling_observation.rb`
- `app/models/scaling_experiment.rb`
- `app/services/scaling_experiment_service.rb`
- `app/services/scaling_analyzer.rb`
- `app/services/scaling_based_allocator.rb`

### Dependencies

- Statistical analysis: `statistical` or similar gem
- Curve fitting: `gsl` or pure Ruby implementation
- Visualization: Charting library for dashboards

### Success Metrics

- Scaling exponents estimated with confidence intervals
- Diminishing returns thresholds identified per dimension
- Dynamic allocation improves outcome/cost ratio by 10%+
- Laws validated across multiple project types

## Validation

### Testing Approach

1. Simulation tests with synthetic scaling functions
2. Holdout validation: Train on 80%, validate on 20%
3. Cross-context validation: Laws from project A predict project B?
4. Temporal validation: Laws stable over time?

### Statistical Rigor

- Minimum 30 samples per experimental condition
- Report confidence intervals on all estimates
- Multiple comparison corrections when testing many hypotheses
- Pre-register hypotheses before experiments

## References

### Related RDRs

- RDR-014: Learned Orchestration Strategies
- RDR-015: End-to-End Outcome Optimization
- RDR-016: Self-Improving Agent Coordination

### Research Resources

- LLM Scaling Laws: [Kaplan et al., 2020](https://arxiv.org/abs/2001.08361)
- Chinchilla Scaling: [Hoffmann et al., 2022](https://arxiv.org/abs/2203.15556)
- Multi-Agent Systems: Scaling literature
- The Bitter Lesson: [Sutton, 2019](https://www.cs.utexas.edu/~eunsol/courses/data/bitter_lesson.pdf)

## Notes

- Start with observational analysis before experiments (cheaper)
- Agent count scaling is highest priority (most actionable)
- Consider diminishing returns thresholds may differ by task type
- Scaling laws should inform but not replace A/B testing of specific changes
- Document findings even if negative (ceiling discovered is valuable knowledge)
- Consider publishing findings to broader community
