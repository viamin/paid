# frozen_string_literal: true

module Activities
  class GenerateStrategyMutationsActivity < BaseActivity
    activity_name "GenerateStrategyMutations"

    def execute(input)
      mutations = with_periodic_heartbeat(
        "generate_strategy_mutations",
        strategy_type: input.fetch(:strategy).fetch(:strategy_type),
        mutation_count: input.fetch(:mutation_count, 2)
      ) do
        StrategyEvolution::GenerateCandidates.call(
          strategy: input.fetch(:strategy),
          analysis: input.slice(:performance, :sample_successes, :sample_failures, :prior_versions),
          options: {
            mutation_count: input.fetch(:mutation_count, 2),
            strategies: input[:strategies]
          }.compact
        )
      end

      {
        strategy_type: input.fetch(:strategy).fetch(:strategy_type),
        mutations: mutations.map do |mutation|
          {
            configuration: mutation.configuration,
            strategy: mutation.strategy,
            reasoning: mutation.reasoning,
            expected_improvement: mutation.expected_improvement,
            diff: mutation.diff,
            provenance: mutation.provenance
          }
        end
      }
    end
  end
end
