# frozen_string_literal: true

module Activities
  class PrepareCoordinationPolicyEvolutionInputsActivity < BaseActivity
    activity_name "PrepareCoordinationPolicyEvolutionInputs"

    def execute(input)
      account = Account.find(input.fetch(:account_id))
      policy_type = input.fetch(:policy_type, CoordinationPolicyEvolution::PrepareInputs::POLICY_TYPE)

      result = CoordinationPolicyEvolution::PrepareInputs.call(
        account: account,
        policy_type: policy_type,
        lookback_days: input.fetch(:lookback_days, CoordinationPolicyEvolution::PrepareInputs::DEFAULT_LOOKBACK_DAYS),
        min_decisions: input.fetch(:min_decisions, CoordinationPolicyEvolution::PrepareInputs::DEFAULT_MIN_DECISIONS),
        sample_limit: input.fetch(:sample_limit, CoordinationPolicyEvolution::PrepareInputs::DEFAULT_SAMPLE_LIMIT)
      )

      result.merge(account_id: account.id, policy_type: policy_type)
    end
  end
end
