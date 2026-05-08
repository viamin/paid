# frozen_string_literal: true

module Activities
  class PrepareStrategyEvolutionInputsActivity < BaseActivity
    activity_name "PrepareStrategyEvolutionInputs"

    def execute(input)
      account = Account.find(input.fetch(:account_id))
      strategy_type = input.fetch(:strategy_type)

      result = StrategyEvolution::PrepareInputs.call(
        strategy_type: strategy_type,
        account: account,
        lookback_days: input.fetch(:lookback_days, StrategyEvolution::PrepareInputs::DEFAULT_LOOKBACK_DAYS),
        min_decisions: input.fetch(:min_decisions, StrategyEvolution::PrepareInputs::DEFAULT_MIN_DECISIONS),
        sample_limit: input.fetch(:sample_limit, StrategyEvolution::PrepareInputs::DEFAULT_SAMPLE_LIMIT)
      )

      result.merge(account_id: account.id, strategy_type: strategy_type)
    end
  end
end
