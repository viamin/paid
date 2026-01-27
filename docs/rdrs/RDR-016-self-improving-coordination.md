# RDR-016: Self-Improving Agent Coordination

> Revise during planning; lock at implementation. If wrong, abandon code and iterate RDR.

## Metadata
- **Date**: 2025-01-26
- **Status**: Draft
- **Type**: Architecture
- **Priority**: Medium
- **Related Issues**: N/A (future enhancement)
- **Related RDRs**: RDR-007 (Agent Abstraction), RDR-014 (Learned Orchestration), RDR-015 (End-to-End Optimization)

## Problem Statement

Current multi-agent coordination in Paid follows fixed patterns:
- Task decomposition uses a planning prompt with hardcoded structure
- Agent assignment uses rules or a meta-agent with fixed criteria
- Retry decisions use exponential backoff with fixed parameters
- Escalation to humans happens at fixed thresholds

These patterns were designed by humans based on intuition. The system cannot:

1. **Learn** which decomposition patterns work for which task types
2. **Discover** when multiple agents outperform a single agent
3. **Adapt** retry strategies based on failure patterns
4. **Predict** when human intervention will help vs waste time

Self-improving coordination means the system learns these patterns from outcomes.

## Context

### Background

Multi-agent coordination involves several decision types:

| Decision | Current Approach | Learning Opportunity |
|----------|------------------|---------------------|
| **Should we decompose?** | Always decompose if task seems complex | Learn when decomposition helps vs hurts |
| **How to decompose?** | Fixed planning prompt | Learn decomposition patterns per task type |
| **How many agents?** | Fixed parallelism level | Learn optimal agent count per context |
| **Which agents?** | Meta-agent selection | Learn agent-task fit from outcomes |
| **When to retry?** | Fixed policy | Learn which failures are retriable |
| **When to escalate?** | Fixed thresholds | Learn when humans add value |

### The Coordination Problem

Consider a feature request: "Add user authentication with OAuth2 support"

**Current approach** (fixed):
1. Planning agent decomposes into sub-tasks
2. Each sub-task assigned to coding agent
3. Agents run in parallel (fixed: 3 at a time)
4. On failure, retry up to 3 times
5. If still failing, escalate to human

**Learned approach** (adaptive):
1. System recognizes "authentication" tasks have specific patterns
2. Decomposition follows patterns successful for similar tasks
3. Parallelism adjusted: auth tasks need more coordination, use 2 agents
4. Retry strategy: "dependency errors" are retriable, "design errors" need human
5. Escalation: this task type has 80% success without human, don't escalate early

### Why Self-Improvement Matters

**Static coordination is fragile**:
- Optimal coordination depends on project, team, task type
- What works for one codebase may fail for another
- As LLMs improve, optimal coordination patterns change

**Data reveals patterns**:
- "Tasks with >5 sub-tasks have lower success rate" → decompose less
- "Python projects benefit from parallel agents; Ruby projects don't" → adapt parallelism
- "Timeout errors are always recoverable; logic errors rarely are" → smart retry

## Research Findings

### Investigation Areas

1. Multi-agent system coordination literature
2. Adaptive workflow systems
3. Meta-learning for task distribution
4. Online learning for decision-making

### Key Discoveries

**Coordination Decision Points:**

```
Task Arrives
     │
     ▼
┌─────────────────┐
│ DECOMPOSITION   │  Single vs multi-task? How many sub-tasks?
│ DECISION        │  What dependencies between sub-tasks?
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ AGENT           │  Which agent type(s)? How many parallel?
│ ASSIGNMENT      │  Any specialist agents needed?
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ EXECUTION       │  Monitor progress, handle failures
│ MONITORING      │  Detect loops, budget overruns
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ FAILURE         │  Retry same agent? Try different agent?
│ RECOVERY        │  Escalate to human? Abandon?
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ RESULT          │  Merge outputs? Resolve conflicts?
│ AGGREGATION     │  Quality check before PR?
└─────────────────┘
```

**Learnable Patterns:**

1. **Decomposition patterns**: What sub-task structures succeed for which task types?
   ```
   Pattern A: Linear (task1 → task2 → task3) - good for refactoring
   Pattern B: Parallel (task1 || task2 || task3) - good for independent features
   Pattern C: Hierarchical (task1 → (task2a || task2b) → task3) - good for complex features
   ```

2. **Agent affinity**: Which agents perform best on which tasks?
   ```
   Claude Code: Strong on complex refactoring, weak on UI tasks
   Cursor: Strong on full-file changes, weak on surgical edits
   Codex: Fast on simple tasks, struggles with context
   ```

3. **Failure classification**: Which failures are recoverable?
   ```
   Recoverable: Timeout, rate limit, syntax error, missing import
   Maybe recoverable: Test failure, lint error, type error
   Not recoverable: Fundamental misunderstanding, wrong approach, missing context
   ```

4. **Escalation signals**: When do humans actually help?
   ```
   Humans help: Ambiguous requirements, architectural decisions, security review
   Humans don't help: Mechanical errors, well-specified tasks, routine changes
   ```

### Learning Approaches

**For discrete decisions** (decompose yes/no, which agent):
- Contextual bandits with context = task features
- Learn policy mapping context → action

**For structured outputs** (decomposition plan):
- LLM-based generation with learned prompts
- Imitation learning from successful decompositions

**For sequential decisions** (retry, escalate):
- Finite-state learner based on failure patterns
- Decision tree learned from outcome data

## Proposed Solution

### Approach

Implement **Coordination Intelligence** as a learning layer that improves coordination decisions based on outcomes:

1. **Coordination Policies**: Database-stored policies for each decision type
2. **Policy Versioning**: Policies evolve like prompts
3. **Outcome Attribution**: Link coordination decisions to final outcomes
4. **Pattern Mining**: Discover successful patterns from data
5. **Policy Evolution**: LLM proposes improved policies based on patterns

### Technical Design

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    SELF-IMPROVING COORDINATION                               │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                     COORDINATION POLICIES                                ││
│  │                                                                          ││
│  │  coordination_policies                                                   ││
│  │  ├── id, policy_type (decomposition, assignment, retry, escalation)     ││
│  │  ├── context_selector (JSONB: when this policy applies)                 ││
│  │  └── current_version_id                                                 ││
│  │                                                                          ││
│  │  policy_versions                                                         ││
│  │  ├── id, policy_id, version                                             ││
│  │  ├── rules (JSONB: decision rules)                                      ││
│  │  ├── parameters (JSONB: thresholds, weights)                            ││
│  │  ├── llm_prompt (for LLM-based decisions)                               ││
│  │  └── reasoning (why this version)                                       ││
│  │                                                                          ││
│  │  coordination_decisions                                                  ││
│  │  ├── agent_run_id, policy_version_id                                    ││
│  │  ├── decision_type, context_snapshot                                    ││
│  │  ├── decision_made (JSONB: the actual decision)                         ││
│  │  └── outcome_contribution (attributed score)                            ││
│  │                                                                          ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                     DECISION SERVICES                                    ││
│  │                                                                          ││
│  │  DecompositionService                                                    ││
│  │  ├── should_decompose?(task, context) → boolean                         ││
│  │  ├── generate_decomposition(task, context) → subtasks                   ││
│  │  └── Policy determines: complexity threshold, max subtasks, structure   ││
│  │                                                                          ││
│  │  AgentAssignmentService                                                  ││
│  │  ├── select_agents(subtasks, context) → agent assignments               ││
│  │  ├── determine_parallelism(subtasks, context) → int                     ││
│  │  └── Policy determines: agent-task fit, parallel vs serial              ││
│  │                                                                          ││
│  │  FailureRecoveryService                                                  ││
│  │  ├── classify_failure(error, context) → failure_type                    ││
│  │  ├── should_retry?(failure_type, attempt) → boolean                     ││
│  │  ├── select_recovery_action(failure, context) → action                  ││
│  │  └── Policy determines: retriable errors, max retries, backoff          ││
│  │                                                                          ││
│  │  EscalationService                                                       ││
│  │  ├── should_escalate?(run_state, context) → boolean                     ││
│  │  ├── generate_escalation_context(run) → human_readable_summary          ││
│  │  └── Policy determines: escalation triggers, human value prediction     ││
│  │                                                                          ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                     LEARNING PIPELINE                                    ││
│  │                                                                          ││
│  │  1. COLLECT: Log all coordination decisions with context                ││
│  │     └─► coordination_decisions table                                    ││
│  │                                                                          ││
│  │  2. ATTRIBUTE: Link decisions to final outcomes                         ││
│  │     └─► outcome_contribution score per decision                         ││
│  │                                                                          ││
│  │  3. ANALYZE: Mine patterns from successful vs failed coordination       ││
│  │     └─► "Parallel execution fails for auth tasks"                       ││
│  │     └─► "Retry helps for timeout, not for logic errors"                 ││
│  │                                                                          ││
│  │  4. PROPOSE: LLM generates improved policies based on patterns          ││
│  │     └─► New policy versions with reasoning                              ││
│  │                                                                          ││
│  │  5. TEST: A/B test new policies against baseline                        ││
│  │     └─► Statistical validation before promotion                         ││
│  │                                                                          ││
│  │  6. PROMOTE: Winners become new defaults                                ││
│  │     └─► Continuous improvement cycle                                    ││
│  │                                                                          ││
│  └─────────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────┘
```

### Implementation Example

```ruby
# app/services/decomposition_service.rb
class DecompositionService
  def should_decompose?(task:, context:)
    policy = find_policy(:decomposition, context)

    # Evaluate rules from policy
    rules = policy.current_version.rules

    score = 0
    score += rules['complexity_weight'] * estimate_complexity(task)
    score += rules['size_weight'] * task.description.length
    score += rules['code_refs_weight'] if task.has_code_references?

    decision = score > rules['decomposition_threshold']

    log_decision(
      policy: policy,
      decision_type: :should_decompose,
      context: context,
      decision: decision,
      score: score
    )

    decision
  end

  def generate_decomposition(task:, context:)
    policy = find_policy(:decomposition, context)

    # Use LLM with policy-specified prompt
    prompt = policy.current_version.llm_prompt
    params = policy.current_version.parameters

    response = generate_with_llm(
      prompt: prompt,
      task: task,
      max_subtasks: params['max_subtasks'],
      structure_hint: params['preferred_structure']
    )

    subtasks = parse_decomposition(response)

    log_decision(
      policy: policy,
      decision_type: :decomposition_plan,
      context: context,
      decision: subtasks.map(&:summary)
    )

    subtasks
  end

  private

  def find_policy(type, context)
    CoordinationPolicy
      .where(policy_type: type)
      .find { |p| p.matches_context?(context) } ||
      CoordinationPolicy.default_for(type)
  end
end

# app/services/failure_recovery_service.rb
class FailureRecoveryService
  def classify_failure(error:, context:)
    policy = find_policy(:failure_classification, context)
    classifier = policy.current_version.rules

    # Pattern matching against known failure types
    failure_type = classifier['patterns'].find do |pattern, type|
      error.message.match?(Regexp.new(pattern))
    end&.last || 'unknown'

    FailureClassification.new(
      type: failure_type,
      recoverable: classifier['recoverable_types'].include?(failure_type),
      suggested_action: classifier['actions'][failure_type]
    )
  end

  def should_retry?(failure:, attempt:, context:)
    return false unless failure.recoverable?

    policy = find_policy(:retry, context)
    rules = policy.current_version.rules

    max_retries = rules['max_retries_by_type'][failure.type] || rules['default_max_retries']

    decision = attempt < max_retries

    log_decision(
      policy: policy,
      decision_type: :should_retry,
      context: context.merge(failure_type: failure.type, attempt: attempt),
      decision: decision
    )

    decision
  end

  def select_recovery_action(failure:, context:)
    policy = find_policy(:recovery, context)
    actions = policy.current_version.rules['recovery_actions']

    # Score each possible action based on failure type and context
    scored_actions = actions.map do |action, config|
      score = config['base_score']
      score += config['failure_type_bonus'][failure.type] || 0
      score += evaluate_context_rules(config['context_rules'], context)
      [action, score]
    end

    selected = scored_actions.max_by(&:last).first

    log_decision(
      policy: policy,
      decision_type: :recovery_action,
      context: context.merge(failure_type: failure.type),
      decision: selected,
      alternatives: scored_actions.to_h
    )

    selected.to_sym
  end
end

# app/services/escalation_service.rb
class EscalationService
  def should_escalate?(run_state:, context:)
    policy = find_policy(:escalation, context)
    rules = policy.current_version.rules

    # Check explicit triggers
    return true if explicit_trigger?(run_state, rules['triggers'])

    # Predict whether human intervention will help
    human_value = predict_human_value(run_state, context, rules)

    decision = human_value > rules['escalation_threshold']

    log_decision(
      policy: policy,
      decision_type: :should_escalate,
      context: context.merge(run_state: run_state.summary),
      decision: decision,
      human_value_prediction: human_value
    )

    decision
  end

  private

  def predict_human_value(run_state, context, rules)
    # Factors that suggest human intervention will help
    value = 0.0

    # Ambiguous requirements increase human value
    value += rules['weights']['ambiguity'] * run_state.ambiguity_score

    # Repeated failures suggest fundamental problem
    value += rules['weights']['repeated_failure'] * (run_state.failure_count / 5.0).clamp(0, 1)

    # Architectural impact increases human value
    value += rules['weights']['architectural'] if context[:involves_architecture]

    # Historical success rate for this task type without human
    historical_rate = lookup_historical_success(context[:task_type], without_human: true)
    value += rules['weights']['historical'] * (1.0 - historical_rate)

    value.clamp(0, 1)
  end
end
```

### Policy Evolution

```ruby
# app/workflows/policy_evolution_workflow.rb
class PolicyEvolutionWorkflow
  include Temporalio::Workflow

  EVOLUTION_PROMPT = <<~PROMPT
    You are analyzing coordination policies for a multi-agent software development system.

    ## Current Policy: {{policy.policy_type}}
    {{policy.current_version.to_yaml}}

    ## Decision Outcomes Analysis
    Total decisions: {{analysis.total_decisions}}
    Success rate: {{analysis.success_rate}}

    ## Patterns in Successful Decisions
    {{analysis.success_patterns}}

    ## Patterns in Failed Decisions
    {{analysis.failure_patterns}}

    ## Sample Successful Coordinations
    {{analysis.success_samples}}

    ## Sample Failed Coordinations
    {{analysis.failure_samples}}

    ## Task
    Propose 2 improved policies that address the failure patterns.

    Consider:
    - What rules or thresholds should change?
    - Are there context factors not being considered?
    - Should the decision logic be restructured?

    Output JSON:
    {
      "mutations": [
        {
          "rules": { ... },
          "parameters": { ... },
          "reasoning": "Why this should improve outcomes"
        }
      ]
    }
  PROMPT

  def execute(policy_id)
    policy = activity.fetch_policy(policy_id)

    # Check eligibility
    return { status: :too_recent } if policy.last_evolved_at&.> 14.days.ago
    return { status: :test_active } if policy.ab_tests.running.exists?

    # Analyze coordination outcomes
    decisions = activity.fetch_decisions(policy_id, days: 60)
    return { status: :insufficient_data } if decisions.count < 50

    analysis = activity.analyze_policy_performance(decisions)

    return { status: :satisfactory } if analysis[:success_rate] >= 0.85

    # Generate mutations
    mutations = activity.generate_policy_mutations(policy, analysis)

    # Create new versions and A/B test
    new_versions = mutations.map do |mutation|
      activity.create_policy_version(policy, mutation)
    end

    test = activity.create_policy_ab_test(policy, new_versions)
    activity.start_ab_test(test.id)

    { status: :evolution_started, ab_test_id: test.id }
  end
end
```

### Decision Rationale

1. **Policies as data**: Coordination logic is configuration, enabling evolution
2. **Context-awareness**: Different policies for different situations
3. **Outcome attribution**: Every decision linked to final outcome
4. **LLM-based evolution**: Semantically meaningful improvements
5. **Statistical validation**: A/B testing before promotion

## Alternatives Considered

### Alternative 1: Fixed Coordination Rules

**Description**: Keep current hardcoded coordination logic

**Pros**:
- Simple, predictable
- Easy to understand and debug

**Cons**:
- Cannot adapt to different contexts
- Suboptimal for many situations
- Requires manual tuning

**Reason for rejection**: Violates Bitter Lesson. Coordination should improve from data.

### Alternative 2: Full Reinforcement Learning

**Description**: Train RL agent to make all coordination decisions

**Pros**:
- Optimal policy in theory
- Handles sequential decisions naturally

**Cons**:
- Very high sample complexity
- Hard to incorporate prior knowledge
- Black box decisions

**Reason for rejection**: Sample efficiency too low. Each sample is an expensive agent run.

### Alternative 3: Human-in-the-Loop Only

**Description**: Always escalate uncertain decisions to humans

**Pros**:
- Human judgment on hard decisions
- Safe by default

**Cons**:
- Doesn't scale
- Humans become bottleneck
- No learning over time

**Reason for rejection**: Goal is autonomous improvement. Humans should be escalation, not default.

## Trade-offs and Consequences

### Positive Consequences

- **Adaptive coordination**: Policies improve from outcomes
- **Context-specific optimization**: Different patterns for different projects
- **Reduced human tuning**: System discovers optimal parameters
- **Knowledge preservation**: Learned patterns persist

### Negative Consequences

- **Complexity**: Multiple learning systems to maintain
- **Cold start**: Needs data before learning helps
- **Debugging difficulty**: Decisions may be hard to explain
- **Evolution cost**: LLM calls for policy generation

### Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Learned policies perform worse | A/B testing with statistical significance |
| Over-specialization | Include diverse contexts in optimization |
| Cascading failures from bad policy | Guardrails and anomaly detection |
| Loss of interpretability | Keep human-readable policy rules |

## Implementation Plan

### Prerequisites

- [ ] Multi-agent orchestration working (Phase 3)
- [ ] Coordination decision logging infrastructure
- [ ] A/B testing framework (RDR-009)
- [ ] Sufficient execution history

### Phase 1: Decision Logging

1. Create coordination decision tables
2. Instrument existing coordination code
3. Build analysis queries
4. Dashboard for coordination metrics

### Phase 2: Policy Data Model

1. Create policy and version tables
2. Extract hardcoded rules into policies
3. Implement policy selection by context
4. Wire services to use policies

### Phase 3: Evolution System

1. Create policy evolution workflow
2. Implement analysis activities
3. Integrate with A/B testing
4. Schedule periodic evolution

### Files to Create

- `db/migrate/xxx_create_coordination_policies.rb`
- `db/migrate/xxx_create_coordination_decisions.rb`
- `app/models/coordination_policy.rb`
- `app/models/policy_version.rb`
- `app/models/coordination_decision.rb`
- `app/services/decomposition_service.rb`
- `app/services/agent_assignment_service.rb`
- `app/services/failure_recovery_service.rb`
- `app/services/escalation_service.rb`
- `app/workflows/policy_evolution_workflow.rb`

### Success Metrics

- All coordination decisions logged with context
- Policies selected based on context
- Evolution produces measurable improvements
- Success rate improves 5%+ over baseline

## Validation

### Testing Approach

1. Unit tests for each decision service
2. Integration tests for policy selection
3. Simulation tests for evolution workflow
4. A/B test: learned vs fixed policies

### Performance Validation

- Decision services add < 20ms latency
- Policy selection is cached where appropriate
- Evolution workflow completes in < 10 minutes

## References

### Related RDRs

- RDR-007: Agent CLI Abstraction
- RDR-009: Prompt Evolution System
- RDR-014: Learned Orchestration Strategies
- RDR-015: End-to-End Outcome Optimization

### Research Resources

- Multi-Agent Systems: [MAS Survey](https://www.cs.cmu.edu/~./softagents/papers/multiagentsurvey.pdf)
- Adaptive Workflow: [Business Process Adaptation](https://link.springer.com/article/10.1007/s10270-015-0456-2)
- The Bitter Lesson: [Sutton, 2019](https://www.cs.utexas.edu/~eunsol/courses/data/bitter_lesson.pdf)

## Notes

- Start with failure recovery policies (highest signal, clearest outcomes)
- Decomposition policies are highest impact but need more data
- Consider human review for escalation policy changes (safety-critical)
- Coordination learning can feed into prompt evolution (surface coordination insights)
