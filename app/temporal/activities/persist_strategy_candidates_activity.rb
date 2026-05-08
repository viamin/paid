# frozen_string_literal: true

module Activities
  class PersistStrategyCandidatesActivity < BaseActivity
    activity_name "PersistStrategyCandidates"

    Mutation = Struct.new(
      :configuration,
      :strategy,
      :reasoning,
      :expected_improvement,
      :diff,
      :provenance,
      keyword_init: true
    )

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

      candidates = StrategyEvolution::CreateCandidates.call(
        strategy_snapshot: input.fetch(:strategy),
        account: account,
        mutations: mutations
      )

      {
        strategy_type: input.fetch(:strategy).fetch(:strategy_type),
        candidate_ids: candidates.map(&:id),
        candidate_count: candidates.size
      }
    end
  end
end
