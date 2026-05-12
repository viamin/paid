# frozen_string_literal: true

module Models
  class RulesBasedSelector
    include RunnerTierLookup

    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:)
      @agent_run = agent_run
    end

    def call
      complexity = estimate_complexity
      tier = TierForComplexity.call(complexity: complexity, agent_run: agent_run)
      candidates = build_candidates(complexity: complexity, tier: tier)

      return nil if candidates.empty?

      selected = candidates.first

      {
        model: selected,
        selector_type: "rules",
        tier: tier,
        reasoning: "Rules-based selection: complexity=#{complexity.round(1)}, tier=#{tier || 'unknown'}, " \
                   "selected #{selected.display_name} (capability=#{selected.capability_score})",
        candidates: candidates,
        complexity_score: complexity
      }
    end

    # Public so collaborators (e.g. MetaAgentSelector) can reuse the same
    # heuristic to establish an initial tier before the LLM meta-agent runs.
    def estimate_complexity
      # Start low so that simple tasks default to the cheapest appropriate tier.
      # Signals that indicate genuine complexity bump the score upward.
      score = 3.0

      if agent_run.issue.present?
        body_length = agent_run.issue.body.to_s.length
        score += 1.0 if body_length > 500
        score += 1.0 if body_length > 1000
        # Heavily-specified issues (>3000 chars) get a larger bump so the
        # "high" tier remains reachable through rules-based selection even
        # with the low default base (max score: 3+1+1+2+1 = 8 > mid_max).
        score += 2.0 if body_length > 3000
      end

      score += 1.0 if agent_run.existing_pr?
      score -= 1.0 if agent_run.create_issue_goal?

      score.clamp(1.0, 10.0)
    end

    private

    attr_reader :agent_run

    def build_candidates(complexity:, tier:)
      scope = LlmModel.active

      # Exclude models the project has excluded
      excluded = agent_run.project.model_preferences["excluded_model_ids"]
      scope = scope.where.not(model_id: excluded) if excluded.present?

      # Prefer the runner's explicitly configured tier model when available
      runner_model = runner_tier_model(tier)
      return [ runner_model ] if runner_model && !excluded_model?(runner_model, excluded)

      tier_candidates = tier ? tier_scope(scope, tier).to_a : []
      # Fall back to the broader pool when the tier has no active models, so a
      # missing tier mapping never leaves the system with zero candidates.
      return tier_candidates if tier_candidates.any?

      fallback_candidates(scope, complexity)
    end

    def tier_scope(scope, tier)
      ordering = tier == "low" ? cost_asc_ordering : capability_desc_ordering
      scope.by_tier(tier).order(ordering).limit(5)
    end

    # Capability floor preserves the pre-tier behavior for any DB whose models
    # have not been backfilled with `tier`. Without it, currently-complex tasks
    # could pick up low-capability models that the previous logic filtered out.
    def fallback_candidates(scope, complexity)
      if complexity < 4.0
        scope.where("capability_score >= 5 OR capability_score IS NULL")
          .order(cost_asc_ordering).limit(5).to_a
      elsif complexity >= 7.0
        scope.where("capability_score >= 8 OR capability_score IS NULL")
          .order(capability_desc_ordering).limit(5).to_a
      else
        scope.order(capability_desc_ordering).limit(5).to_a
      end
    end

    def capability_desc_ordering
      Arel.sql("capability_score DESC NULLS LAST")
    end

    def cost_asc_ordering
      Arel.sql("input_cost_per_million ASC NULLS LAST")
    end
  end
end
