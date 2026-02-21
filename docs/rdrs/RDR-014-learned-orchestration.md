# RDR-014: Learned Orchestration Strategies

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata

- **Date**: 2025-01-26
- **Status**: Draft
- **Type**: Architecture
- **Priority**: Medium
- **Related Issues**: N/A (future enhancement)
- **Related RDRs**: RDR-002 (Workflow Orchestration), RDR-009 (Prompt Evolution)

## Problem Statement

Paid's current orchestration layer uses hand-designed workflows: poll issues → plan → execute → create PR. While functional, this approach:

1. **Encodes human assumptions** about optimal task decomposition
2. **Cannot adapt** to different project types or task categories
3. **Misses optimization opportunities** that data might reveal
4. **Doesn't scale with compute** — more resources don't improve orchestration quality

To genuinely apply the Bitter Lesson, the orchestration strategy itself should be learned from outcomes rather than designed by humans.

## Context

### Background

The Bitter Lesson (Sutton, 2019) argues that general methods leveraging computation beat hand-crafted approaches. Currently, Paid applies this principle to:

- **Prompt evolution**: LLM-based mutation with A/B testing (RDR-009)
- **Model selection**: Meta-agent chooses models based on task context (RDR-008)

But the orchestration layer — the decision of *how* to coordinate agents — remains hand-designed:

```
Current: Human designs workflow → Workflow executes → Outcome measured

Proposed: Outcomes measured → System learns patterns → Workflow adapts
```

### Technical Environment

- Temporal.io for workflow orchestration
- PostgreSQL for storing execution history
- Quality metrics already collected per agent run
- Rich execution traces available (iterations, timing, failures)

### What "Learned Orchestration" Means

Instead of fixed workflow patterns, the system would:

1. **Observe** which orchestration decisions lead to successful outcomes
2. **Learn** patterns correlating decisions with success/failure
3. **Propose** orchestration strategies for new tasks
4. **Test** strategies via controlled experiments
5. **Adapt** based on measured performance

## Research Findings

### Investigation Areas

1. Workflow mining and process discovery literature
2. Reinforcement learning for sequential decision-making
3. Contextual bandits for action selection
4. Meta-learning for task adaptation

### Key Discoveries

**Orchestration Decision Points:**

| Decision | Current Approach | Learnable Alternative |
|----------|------------------|----------------------|
| Task decomposition | Fixed planning prompt | Learn decomposition patterns from successful projects |
| Agent selection | Meta-agent with rules | Learn which agent types succeed for which tasks |
| Parallelization | Fixed parallel vs serial | Learn optimal parallelism per task type |
| Retry strategy | Fixed backoff | Learn retry patterns that actually help |
| Escalation | Fixed thresholds | Learn when human intervention helps |

**Data Available for Learning:**

```
For each agent run:
- Issue characteristics (labels, description length, code references)
- Project characteristics (language, size, test coverage)
- Orchestration decisions made (decomposition, agent choice, parallelism)
- Execution trace (iterations, timing, tool usage)
- Outcome (PR merged, CI passed, human feedback)
```

**Potential Learning Approaches:**

1. **Contextual Bandits**: For discrete decisions (which agent, how many retries)
   - Lower sample complexity than full RL
   - Well-understood exploration/exploitation tradeoffs
   - Can incorporate prior knowledge

2. **Imitation Learning**: Learn from successful execution traces
   - Requires labeled "expert" trajectories
   - Can bootstrap from initial hand-designed workflows
   - May overfit to specific patterns

3. **LLM-based Strategy Generation**: Use LLMs to propose orchestration strategies
   - Similar to prompt evolution approach
   - Interpretable strategies
   - Can incorporate reasoning about why patterns work

4. **Bayesian Optimization**: Tune continuous orchestration parameters
   - Sample-efficient for parameter tuning
   - Good for parallelism levels, timeout values
   - Less applicable to discrete structural decisions

### Design Principle: Build for Full Autonomy

Design and build the complete system from the start — decision logging, context-aware strategy selection, LLM-based evolution, and A/B testing all deployed together. Some components will naturally become active only after sufficient data accumulates (strategy evolution requires ~30 decision records), but the architecture should be complete from day one rather than built in graduated phases.

This avoids building a "recommendation-only" system and later rebuilding it as an "automated" system. The full pipeline is:

- Log all orchestration decisions with full context
- Select strategies based on context using the full selection engine
- Evolve strategies via LLM-based mutation when sufficient data exists
- A/B test evolved strategies with automatic promotion (with guardrails)
- Human oversight for anomalies via alerting, not manual gating

## Proposed Solution

### Approach

Implement **LLM-based orchestration strategy evolution** (similar to prompt evolution) combined with **contextual bandits** for discrete decisions:

1. **Strategy as Data**: Orchestration strategies stored in database, not code
2. **Context Encoding**: Rich feature vectors for tasks and projects
3. **Decision Logging**: Every orchestration decision logged with context
4. **Outcome Attribution**: Quality metrics attributed to orchestration decisions
5. **Strategy Evolution**: LLM proposes new strategies based on failure analysis
6. **A/B Testing**: Statistical validation before promotion

### Technical Design

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    LEARNED ORCHESTRATION SYSTEM                              │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                     ORCHESTRATION STRATEGY                               ││
│  │                                                                          ││
│  │  strategies                                                              ││
│  │  ├── id, slug, name                                                     ││
│  │  ├── task_type (issue, feature, bug, refactor)                         ││
│  │  ├── project_context_rules (language, size, etc.)                      ││
│  │  └── current_version_id                                                 ││
│  │                                                                          ││
│  │  strategy_versions                                                       ││
│  │  ├── decomposition_approach (single, parallel, hierarchical)            ││
│  │  ├── agent_selection_rules                                              ││
│  │  ├── parallelism_config                                                 ││
│  │  ├── retry_policy                                                       ││
│  │  ├── escalation_rules                                                   ││
│  │  └── reasoning (why this strategy)                                      ││
│  │                                                                          ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                     DECISION LOGGING                                     ││
│  │                                                                          ││
│  │  orchestration_decisions                                                 ││
│  │  ├── agent_run_id                                                       ││
│  │  ├── strategy_version_id                                                ││
│  │  ├── decision_type (decompose, select_agent, parallelize, retry, etc.) ││
│  │  ├── context_snapshot (JSON: issue features, project features)         ││
│  │  ├── decision_value (what was decided)                                  ││
│  │  ├── alternatives_considered                                            ││
│  │  └── outcome_contribution (attributed quality impact)                   ││
│  │                                                                          ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                     LEARNING PIPELINE                                    ││
│  │                                                                          ││
│  │  1. Collect: Log decisions with context and outcomes                    ││
│  │  2. Analyze: Identify patterns in successful vs failed orchestrations   ││
│  │  3. Propose: LLM generates strategy mutations addressing failures       ││
│  │  4. Test: A/B test new strategies against baseline                      ││
│  │  5. Promote: Winners become new defaults                                ││
│  │  6. Repeat: Continuous improvement cycle                                ││
│  │                                                                          ││
│  └─────────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────┘
```

### Strategy Selection Flow

```ruby
class OrchestrationStrategySelector
  def select(issue:, project:)
    # Encode context
    context = encode_context(issue, project)

    # Find applicable strategies
    candidates = Strategy.where(task_type: classify_task(issue))
                        .where("project_context_rules @> ?", context.to_json)

    # Check for active A/B test
    active_test = candidates.flat_map(&:ab_tests).find(&:running?)

    if active_test
      # Assign to variant
      variant = ABTestAssigner.assign(active_test, issue.id)
      log_decision(:strategy_selection, context, variant.strategy_version, :ab_test)
      return variant.strategy_version
    end

    # Use best performing strategy for context
    best = candidates.max_by { |s| s.quality_score_for_context(context) }
    log_decision(:strategy_selection, context, best.current_version, :best_match)
    best.current_version
  end

  private

  def encode_context(issue, project)
    {
      issue_type: classify_issue_type(issue),
      issue_complexity: estimate_complexity(issue),
      issue_has_code_refs: issue.body.match?(/```/),
      project_language: project.primary_language,
      project_size: project.loc_bucket,
      project_test_coverage: project.test_coverage_bucket,
      project_historical_success_rate: project.agent_success_rate
    }
  end
end
```

### Strategy Evolution

```ruby
class StrategyEvolutionWorkflow
  include Temporalio::Workflow

  EVOLUTION_PROMPT = <<~PROMPT
    You are analyzing orchestration strategies for an AI agent system.

    ## Current Strategy
    {{strategy.to_yaml}}

    ## Performance Analysis
    Success rate: {{analysis.success_rate}}
    Average iterations: {{analysis.avg_iterations}}
    Common failure patterns:
    {{analysis.failure_patterns}}

    ## Failed Executions
    {{analysis.failure_samples}}

    ## Successful Executions
    {{analysis.success_samples}}

    ## Task
    Propose 2 improved orchestration strategies that address the failure patterns.

    Consider:
    - Should tasks be decomposed differently?
    - Would different agent selection help?
    - Is the parallelism level appropriate?
    - Are retry policies effective?
    - When should humans be involved?

    Output JSON:
    {
      "mutations": [
        {
          "strategy": { decomposition_approach, agent_selection_rules, ... },
          "reasoning": "Why this should help",
          "expected_improvement": "What metric should improve"
        }
      ]
    }
  PROMPT

  def execute(strategy_id)
    strategy = activity.fetch_strategy(strategy_id)

    # Check eligibility (same as prompt evolution)
    return { status: :too_recent } if strategy.last_evolved_at&.> 14.days.ago
    return { status: :test_active } if strategy.ab_tests.running.exists?

    # Analyze performance
    decisions = activity.fetch_decisions(strategy_id, days: 60)
    return { status: :insufficient_data } if decisions.count < 30

    analysis = activity.analyze_strategy_performance(decisions)

    return { status: :satisfactory } if analysis[:success_rate] >= 0.80

    # Generate mutations
    mutations = activity.generate_strategy_mutations(strategy, analysis)

    # Create A/B test
    test = activity.create_strategy_ab_test(strategy, mutations)
    activity.start_ab_test(test.id)

    { status: :evolution_started, ab_test_id: test.id }
  end
end
```

### Decision Rationale

1. **Strategies as data**: Orchestration logic is configuration, not code
2. **Context-aware selection**: Different projects/tasks get different strategies
3. **LLM-based evolution**: Semantically meaningful improvements (vs random mutation)
4. **A/B testing validation**: Statistical rigor before promotion
5. **Gradual autonomy**: Start with recommendations, progress to full automation

## Alternatives Considered

### Alternative 1: Reinforcement Learning

**Description**: Train an RL agent to make orchestration decisions

**Pros**:

- Optimal policy in theory
- Handles sequential decisions naturally

**Cons**:

- High sample complexity (needs many runs to learn)
- Reward design is tricky (sparse, delayed)
- Hard to incorporate prior knowledge
- Black box decisions

**Reason for rejection**: Sample efficiency too low for initial implementation. LLM-based approach can bootstrap faster.

### Alternative 2: Static Rule Mining

**Description**: Mine association rules from successful executions

**Pros**:

- Interpretable rules
- No LLM cost
- Works with existing data

**Cons**:

- Captures correlation, not causation
- Can't generalize beyond observed patterns
- Requires careful feature engineering

**Reason for rejection**: Limited generalization. LLM can reason about *why* patterns work.

### Alternative 3: Human-Curated Strategy Library

**Description**: Humans design multiple strategies, system selects based on context

**Pros**:

- Human expertise captured
- Fully interpretable
- No learning complexity

**Cons**:

- Doesn't scale with data
- Can't discover novel strategies
- Maintenance burden

**Reason for rejection**: Violates Bitter Lesson. Human curation should bootstrap, not be the end state.

## Trade-offs and Consequences

### Positive Consequences

- **Continuous improvement**: Orchestration gets better with more data
- **Context adaptation**: Strategies optimized per project type
- **Reduced human design burden**: System discovers what works
- **Scalable with compute**: More A/B tests → faster learning

### Negative Consequences

- **Complexity**: Another learning system to maintain
- **Cold start**: Needs data before learning is useful
- **Interpretability**: Some learned patterns may be opaque
- **Evolution cost**: LLM calls for strategy generation

### Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Learned strategies perform worse than baseline | A/B testing with statistical significance required |
| Over-specialization to specific projects | Include generalization metrics in fitness function |
| Strategy drift from original intent | Human review gate for evolved strategies |
| Cold start with no data | Bootstrap from hand-designed strategies |

## Implementation Plan

### Prerequisites

- [ ] RDR-002 (Temporal) implemented
- [ ] RDR-009 (Prompt Evolution) implemented — provides A/B testing infrastructure
- [ ] Quality metrics collection working
- [ ] Sufficient execution history (100+ runs recommended)

### Implementation Steps

1. Create `orchestration_decisions`, `strategies`, and `strategy_versions` tables
2. Instrument current workflows to log all decisions with full context
3. Extract current hardcoded strategies into database as initial strategy versions
4. Implement `OrchestrationStrategySelector` with context-aware selection
5. Create `StrategyEvolutionWorkflow` with LLM-based strategy mutation
6. Integrate with A/B test infrastructure for strategy validation
7. Schedule periodic evolution checks (activates when sufficient data exists)
8. Build dashboard showing orchestration metrics and strategy performance

### Files to Create

- `db/migrate/xxx_create_orchestration_decisions.rb`
- `db/migrate/xxx_create_strategies.rb`
- `app/models/strategy.rb`
- `app/models/strategy_version.rb`
- `app/models/orchestration_decision.rb`
- `app/services/orchestration_strategy_selector.rb`
- `app/workflows/strategy_evolution_workflow.rb`
- `app/activities/strategy_evolution_activities.rb`

### Success Metrics

- 100% of orchestration decisions logged with context
- Strategy selection based on context working
- First strategy A/B test completed with measurable outcome

## Validation

### Testing Approach

1. Unit tests for strategy selection logic
2. Integration tests for decision logging
3. Workflow tests for evolution process
4. Statistical validation of A/B test analysis

### Performance Validation

- Strategy selection adds < 10ms to workflow startup
- Decision logging is async (no latency impact)
- Evolution workflow completes in < 10 minutes

## References

### Related RDRs

- RDR-002: Workflow Orchestration (Temporal.io)
- RDR-009: Prompt Evolution System (A/B testing infrastructure)

### Research Resources

- Contextual Bandits: [Tutorial](https://arxiv.org/abs/1904.07272)
- Process Mining: [IEEE Task Force](https://www.tf-pm.org/)
- The Bitter Lesson: [Sutton, 2019](https://www.cs.utexas.edu/~eunsol/courses/data/bitter_lesson.pdf)

## Notes

- Strategy evolution naturally activates once sufficient data exists (~30 decisions logged). The system is idle but ready before that threshold.
- Strategy evolution cadence should be slower than prompt evolution (strategies are higher-stakes)
- Anomaly alerting replaces manual review gates — the system operates autonomously with human oversight via alerts
