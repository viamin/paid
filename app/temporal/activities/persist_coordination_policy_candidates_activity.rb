# frozen_string_literal: true

module Activities
  class PersistCoordinationPolicyCandidatesActivity < BaseActivity
    activity_name "PersistCoordinationPolicyCandidates"

    Mutation = StrategyEvolution::Mutate::Mutation

    def execute(input)
      account = Account.find(input.fetch(:account_id))
      mutations = Array(input.fetch(:mutations, [])).map do |mutation|
        Mutation.new(**mutation.slice(
          :configuration,
          :strategy,
          :reasoning,
          :expected_improvement,
          :diff,
          :provenance
        ))
      end

      candidates = CoordinationPolicyEvolution::CreateCandidates.call(
        policy_snapshot: input.fetch(:policy),
        account: account,
        mutations: mutations
      )

      {
        policy_type: input.fetch(:policy).fetch(:policy_type),
        candidate_ids: candidates.map(&:id),
        candidate_count: candidates.size
      }
    end
  end
end
