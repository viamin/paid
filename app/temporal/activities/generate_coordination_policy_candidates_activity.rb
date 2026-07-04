# frozen_string_literal: true

module Activities
  class GenerateCoordinationPolicyCandidatesActivity < BaseActivity
    activity_name "GenerateCoordinationPolicyCandidates"

    def execute(input)
      mutations = with_periodic_heartbeat(
        "generate_coordination_policy_candidates",
        policy_type: input.fetch(:policy).fetch(:policy_type),
        mutation_count: input.fetch(:mutation_count, 2)
      ) do
        CoordinationPolicyEvolution::GenerateCandidates.call(
          policy: input.fetch(:policy),
          analysis: input.slice(:performance, :sample_successes, :sample_failures, :prior_versions),
          options: {
            mutation_count: input.fetch(:mutation_count, 2),
            strategies: input[:strategies]
          }.compact
        )
      end

      {
        policy_type: input.fetch(:policy).fetch(:policy_type),
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
