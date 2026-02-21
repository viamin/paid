# RDR-015: End-to-End Outcome Optimization

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2025-01-26
- **Status**: Draft
- **Type**: Architecture
- **Priority**: Medium
- **Related Issues**: N/A (future enhancement)
- **Related RDRs**: RDR-009 (Prompt Evolution), RDR-014 (Learned Orchestration)

## Problem Statement

Paid currently optimizes individual components:

- Prompts are A/B tested and evolved (RDR-009)
- Model selection adapts to task context (RDR-008)

But the **ultimate outcome** — a merged PR that solves the issue — depends on the entire pipeline working together. Local optima don't guarantee global optima:

- A prompt that produces more code might increase CI failures
- An agent that works faster might produce lower-quality PRs
- Parallelization might improve throughput but reduce coordination

**End-to-end optimization** treats the full pipeline (issue → PR merged) as the unit of optimization, attributing outcomes to the entire configuration rather than individual components.

## Context

### Background

Current optimization approach:

```
Issue → [Prompt A] → [Agent B] → [Strategy C] → PR → Outcome
            ↓            ↓            ↓
         Optimize     Optimize     Optimize
         locally      locally      locally
```

End-to-end approach:

```
Issue → [Configuration Bundle] → PR → Outcome
                 ↓
           Optimize bundle
           based on outcome
```

A "configuration bundle" includes:

- Prompt versions for each stage (planning, coding, review)
- Model selections
- Orchestration strategy
- Retry policies
- All tunable parameters

### Why This Matters

**Interaction effects**: Components interact in non-obvious ways:

- A more detailed planning prompt + a concise coding prompt might work better than both being detailed
- Certain model combinations outperform either model alone
- Parallelism benefits depend on task decomposition quality

**Credit assignment**: When a PR fails, what caused it?

- Was the prompt bad?
- Was the model choice wrong?
- Was the orchestration flawed?
- Was it the combination?

End-to-end optimization sidesteps credit assignment by optimizing configurations holistically.

### The Bitter Lesson Connection

The Bitter Lesson argues for methods that scale with compute. End-to-end optimization:

1. **Scales with data**: More completed runs → better configuration understanding
2. **Scales with compute**: Can test more configurations simultaneously
3. **Avoids human assumptions**: Doesn't require knowing which component matters

## Research Findings

### Investigation Areas

1. AutoML and hyperparameter optimization
2. Neural architecture search
3. End-to-end learning in ML pipelines
4. Bayesian optimization for expensive black-box functions

### Key Discoveries

**Configuration Space:**

The full configuration space is large but structured:

```yaml
configuration_bundle:
  prompts:
    planning: prompt_version_id
    coding: prompt_version_id
    review: prompt_version_id

  models:
    planning: model_id
    coding: model_id
    review: model_id

  orchestration:
    strategy_version_id: id
    max_parallel_agents: 1-5
    max_iterations: 3-10
    retry_backoff: exponential|linear|fixed

  thresholds:
    quality_gate: 0.5-0.9
    cost_limit: 1.0-100.0
    time_limit_minutes: 5-120
```

**Dimensionality Reduction:**

Not all combinations need testing:

- **Factored optimization**: Some components are independent
- **Transfer learning**: Similar projects share optimal configs
- **Warm starting**: Start from known-good configurations

**Optimization Approaches:**

| Approach | Sample Efficiency | Handles Interactions | Interpretability |
|----------|-------------------|---------------------|------------------|
| Grid search | Low | Yes | High |
| Random search | Medium | Yes | Medium |
| Bayesian optimization | High | Yes | Medium |
| Evolutionary strategies | Medium | Yes | Low |
| Multi-armed bandits | High | Limited | High |

**Recommendation: Bayesian Optimization with Configuration Bundles**

- Sample-efficient for expensive evaluations (each "sample" is an agent run)
- Handles interaction effects through joint modeling
- Can incorporate prior beliefs about good configurations
- Provides uncertainty estimates for exploration

### Outcome Attribution

For end-to-end optimization, need clear outcome signal:

```ruby
# Composite outcome score
def outcome_score(agent_run)
  weights = {
    pr_merged: 0.40,      # Ultimate success signal
    time_to_merge: 0.15,  # Efficiency (inverted, normalized)
    ci_passed: 0.15,      # Quality
    human_effort: 0.15,   # Autonomy (inverted: less human intervention = better)
    cost: 0.15            # Resource efficiency (inverted, normalized)
  }

  scores = {
    pr_merged: agent_run.pr_merged? ? 1.0 : 0.0,
    time_to_merge: normalize_time(agent_run.time_to_merge),
    ci_passed: agent_run.ci_passed? ? 1.0 : 0.0,
    human_effort: 1.0 - normalize_interventions(agent_run.human_interventions),
    cost: 1.0 - normalize_cost(agent_run.total_cost)
  }

  weights.sum { |metric, weight| scores[metric] * weight }
end
```

## Proposed Solution

### Approach

Implement **Configuration Bundle Optimization** using Bayesian optimization:

1. **Bundle Registry**: Store configuration bundles as versioned entities
2. **Outcome Tracking**: Attribute outcomes to entire bundles
3. **Bayesian Optimizer**: Model outcome as function of configuration
4. **Exploration/Exploitation**: Balance trying new configs vs using known-good
5. **Context-Aware**: Different optimal bundles for different contexts

### Technical Design

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    END-TO-END OPTIMIZATION SYSTEM                            │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                     CONFIGURATION BUNDLES                                ││
│  │                                                                          ││
│  │  configuration_bundles                                                   ││
│  │  ├── id, name, context_selector                                         ││
│  │  ├── prompt_versions (JSONB: {planning: id, coding: id, review: id})   ││
│  │  ├── model_preferences (JSONB: {planning: id, coding: id, ...})        ││
│  │  ├── orchestration_config (JSONB: strategy, parallelism, retries)      ││
│  │  ├── thresholds (JSONB: quality_gate, cost_limit, time_limit)          ││
│  │  └── is_baseline, is_active                                             ││
│  │                                                                          ││
│  │  bundle_outcomes                                                         ││
│  │  ├── configuration_bundle_id                                            ││
│  │  ├── agent_run_id                                                       ││
│  │  ├── context_features (JSONB: project, issue characteristics)          ││
│  │  ├── outcome_score                                                      ││
│  │  └── component_scores (JSONB: pr_merged, ci_passed, cost, etc.)        ││
│  │                                                                          ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                     BAYESIAN OPTIMIZER                                   ││
│  │                                                                          ││
│  │  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐                 ││
│  │  │ Surrogate   │    │ Acquisition │    │ Configuration│                 ││
│  │  │ Model (GP)  │───►│ Function    │───►│ Selector     │                 ││
│  │  └─────────────┘    └─────────────┘    └─────────────┘                 ││
│  │        ▲                                      │                          ││
│  │        │                                      ▼                          ││
│  │        │                              ┌─────────────┐                   ││
│  │        │                              │ Agent Run   │                   ││
│  │        │                              │ with Config │                   ││
│  │        │                              └──────┬──────┘                   ││
│  │        │                                     │                          ││
│  │        │                              ┌──────▼──────┐                   ││
│  │        └──────────────────────────────│ Outcome     │                   ││
│  │                                       │ Observation │                   ││
│  │                                       └─────────────┘                   ││
│  │                                                                          ││
│  │  Surrogate Model: P(outcome | configuration, context)                   ││
│  │  Acquisition: Expected Improvement, UCB, or Thompson Sampling           ││
│  │                                                                          ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                     OPTIMIZATION LOOP                                    ││
│  │                                                                          ││
│  │  1. New task arrives                                                    ││
│  │  2. Encode context (project type, issue complexity, etc.)               ││
│  │  3. Query optimizer: explore new config OR exploit known-good?          ││
│  │  4. Select configuration bundle                                         ││
│  │  5. Execute agent run with bundle                                       ││
│  │  6. Observe outcome                                                     ││
│  │  7. Update surrogate model                                              ││
│  │  8. Repeat                                                              ││
│  │                                                                          ││
│  │  Exploration rate decays as confidence increases                        ││
│  │  Context-specific: optimal configs learned per project type             ││
│  │                                                                          ││
│  └─────────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────┘
```

### Implementation Example

```ruby
# app/services/configuration_optimizer.rb
class ConfigurationOptimizer
  EXPLORATION_RATE = 0.2  # 20% exploration, 80% exploitation

  def select_configuration(context:)
    # Encode context as feature vector
    context_features = encode_context(context)

    # Decide: explore or exploit?
    if should_explore?(context_features)
      select_exploration_config(context_features)
    else
      select_exploitation_config(context_features)
    end
  end

  def record_outcome(bundle:, agent_run:, context:)
    outcome = calculate_outcome_score(agent_run)

    BundleOutcome.create!(
      configuration_bundle: bundle,
      agent_run: agent_run,
      context_features: encode_context(context),
      outcome_score: outcome,
      component_scores: calculate_component_scores(agent_run)
    )

    # Update surrogate model (async)
    SurrogateModelUpdateJob.perform_later(bundle.id)
  end

  private

  def should_explore?(context_features)
    # Explore more when:
    # 1. Few observations for this context
    # 2. High uncertainty in predictions
    # 3. Random exploration with probability EXPLORATION_RATE

    observations = BundleOutcome.similar_context(context_features).count

    if observations < 10
      true  # Always explore with little data
    elsif rand < EXPLORATION_RATE
      true  # Random exploration
    else
      # Explore if uncertainty is high
      uncertainty = surrogate_model.uncertainty(context_features)
      uncertainty > 0.3
    end
  end

  def select_exploration_config(context_features)
    # Use acquisition function to select promising unexplored config
    # Expected Improvement (EI) balances predicted value and uncertainty

    candidates = generate_candidate_bundles(context_features)

    candidates.max_by do |bundle|
      expected_improvement(bundle, context_features)
    end
  end

  def select_exploitation_config(context_features)
    # Use best known configuration for this context
    ConfigurationBundle
      .active
      .with_outcomes_for_context(context_features)
      .order(avg_outcome_score: :desc)
      .first || ConfigurationBundle.baseline
  end

  def expected_improvement(bundle, context)
    # EI = E[max(f(x) - f(x*), 0)]
    # where f(x*) is the best observed value

    best_observed = BundleOutcome.similar_context(context).maximum(:outcome_score) || 0

    mean, std = surrogate_model.predict(bundle, context)

    return 0 if std == 0

    z = (mean - best_observed) / std
    ei = (mean - best_observed) * normal_cdf(z) + std * normal_pdf(z)
    ei
  end
end

# app/models/configuration_bundle.rb
class ConfigurationBundle < ApplicationRecord
  has_many :bundle_outcomes

  scope :active, -> { where(is_active: true) }
  scope :baseline, -> { find_by(is_baseline: true) }

  def avg_outcome_score
    bundle_outcomes.average(:outcome_score)
  end

  def to_execution_config
    {
      prompts: prompt_versions,
      models: model_preferences,
      orchestration: orchestration_config,
      thresholds: thresholds
    }
  end
end
```

### Surrogate Model

```ruby
# app/services/surrogate_model.rb
class SurrogateModel
  # Gaussian Process regression for outcome prediction
  # GP provides both mean prediction and uncertainty estimates,
  # which are essential for principled exploration/exploitation.

  def predict(bundle, context)
    features = encode_bundle_context(bundle, context)

    # Returns (mean, std) of predicted outcome
    gp_predict(features)
  end

  def uncertainty(context)
    # Average uncertainty across configurations for this context
    active_bundles = ConfigurationBundle.active

    uncertainties = active_bundles.map do |bundle|
      _, std = predict(bundle, context)
      std
    end

    uncertainties.sum / uncertainties.size
  end

  def update(new_observation)
    # Incrementally update GP with new data point
    # Or retrain periodically in batch
  end

  private

  def encode_bundle_context(bundle, context)
    # Combine bundle configuration with context features
    # into a single feature vector for the GP

    bundle_features = [
      bundle.prompt_versions.values.map(&:to_i),
      bundle.model_preferences.values.map { |m| model_to_idx(m) },
      bundle.orchestration_config['max_parallel_agents'],
      bundle.orchestration_config['max_iterations'],
      bundle.thresholds['quality_gate']
    ].flatten

    context_features = [
      context[:project_language_idx],
      context[:project_size_bucket],
      context[:issue_complexity],
      context[:issue_type_idx]
    ]

    bundle_features + context_features
  end
end
```

### Decision Rationale

1. **Holistic optimization**: Captures interaction effects between components
2. **Sample efficiency**: Bayesian optimization minimizes costly agent runs
3. **Context-aware**: Different optimal configs for different situations
4. **Exploration/exploitation balance**: Continues improving while performing well
5. **Builds on existing**: Uses prompt versions, model selection as inputs

## Alternatives Considered

### Alternative 1: Optimize Components Independently

**Description**: Keep current approach of optimizing prompts, models, strategies separately

**Pros**:

- Simpler to implement and reason about
- Clear ownership of each component

**Cons**:

- Misses interaction effects
- Local optima may not be global optima
- Credit assignment is ambiguous

**Reason for rejection**: Evidence from ML suggests end-to-end optimization outperforms component-wise.

### Alternative 2: Reinforcement Learning

**Description**: Train RL agent to select configurations sequentially

**Pros**:

- Can handle sequential dependencies
- Learns complex policies

**Cons**:

- Very high sample complexity
- Requires careful reward shaping
- Hard to incorporate prior knowledge

**Reason for rejection**: Each "sample" is an expensive agent run. Bayesian optimization is more sample-efficient.

### Alternative 3: Fixed Configuration Search

**Description**: Test all combinations of component versions

**Pros**:

- Exhaustive coverage
- No modeling assumptions

**Cons**:

- Combinatorial explosion (e.g., 10 prompts × 5 models × 3 strategies = 150 configs)
- Ignores context
- Wastes samples on bad regions

**Reason for rejection**: Bayesian optimization is more sample-efficient by modeling the objective.

## Trade-offs and Consequences

### Positive Consequences

- **Better outcomes**: Optimizes what actually matters (merged PRs)
- **Discovers interactions**: Finds non-obvious component combinations
- **Continuous improvement**: Gets better with more data
- **Context adaptation**: Optimal configs per project type

### Negative Consequences

- **Complexity**: Adds optimization layer on top of existing systems
- **Cold start**: Needs baseline data before optimization is useful
- **Compute cost**: Surrogate model training and inference
- **Interpretability**: Optimal configs may not be intuitive

### Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Optimization diverges | Constrain search space to known-reasonable configs |
| Over-specialization | Include diverse projects in optimization |
| Exploration harms users | Limit exploration to low-stakes tasks initially |
| Model accuracy | Ensemble multiple surrogate models |

## Implementation Plan

### Prerequisites

- [ ] RDR-009 (Prompt Evolution) implemented
- [ ] RDR-008 (Model Selection) implemented
- [ ] Quality metrics collection working
- [ ] Sufficient execution history (50+ runs recommended)

### Implementation Steps

1. Create `configuration_bundles` and `bundle_outcomes` tables
2. Build baseline bundles from current configuration
3. Instrument workflow to record bundle + outcome for every agent run
4. Implement `ConfigurationOptimizer` with Gaussian Process surrogate model
5. Integrate optimizer into workflow execution with exploration/exploitation
6. Add monitoring for optimization metrics
7. Build dashboard for configuration performance and outcome trends

The optimizer activates once sufficient baseline data exists (~50 recorded outcomes). Before that threshold, all runs use baseline configuration while collecting data.

### Files to Create

- `db/migrate/xxx_create_configuration_bundles.rb`
- `db/migrate/xxx_create_bundle_outcomes.rb`
- `app/models/configuration_bundle.rb`
- `app/models/bundle_outcome.rb`
- `app/services/configuration_optimizer.rb`
- `app/services/surrogate_model.rb`
- `app/jobs/surrogate_model_update_job.rb`

### Dependencies

- `numo-narray` for numerical operations
- Gaussian Process implementation (pure Ruby or `torch.rb`)

### Success Metrics

- Outcome score improves 10%+ over baseline after 100 runs
- Optimal configurations differ by context (showing context-awareness)
- Exploration finds configurations that become new best

## Validation

### Testing Approach

1. Unit tests for optimizer selection logic
2. Simulation tests with synthetic outcome function
3. Integration tests for bundle recording
4. A/B test: optimization vs fixed baseline

### Performance Validation

- Configuration selection < 50ms
- Surrogate model update < 5 seconds (async)
- No impact on agent run latency

## References

### Related RDRs

- RDR-008: Model Selection Strategy
- RDR-009: Prompt Evolution System
- RDR-014: Learned Orchestration Strategies

### Research Resources

- Bayesian Optimization: [A Tutorial](https://arxiv.org/abs/1807.02811)
- AutoML: [Auto-sklearn](https://automl.github.io/auto-sklearn/)
- Gaussian Processes: [GPML Book](http://gaussianprocess.org/gpml/)
- The Bitter Lesson: [Sutton, 2019](https://www.cs.utexas.edu/~eunsol/courses/data/bitter_lesson.pdf)

## Notes

- Use Gaussian Process surrogate model from the start — it provides uncertainty estimates needed for principled exploration/exploitation, which Random Forest cannot.
- Exploration should be gated on task importance (don't explore on critical tasks)
- Configuration bundles should be human-reviewable (not just numerical vectors)
- The optimizer is always deployed but only activates exploration once sufficient baseline data exists
