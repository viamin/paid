# frozen_string_literal: true

module StrategyExperiments
  module StrategySnapshot
    module_function

    def serialize(strategy)
      return {} unless strategy

      {
        "id" => strategy.id,
        "strategy_type" => strategy.strategy_type,
        "name" => strategy.name,
        "version" => strategy.version,
        "active" => strategy.respond_to?(:active) ? strategy.active : true,
        "account_id" => strategy.account_id,
        "configuration" => strategy.configuration
      }.compact
    end

    def deserialize(snapshot, account: nil, fallback_strategy_type: nil)
      data = snapshot.deep_stringify_keys

      # Always reconstruct from snapshot data to preserve point-in-time configuration.
      # Returning the live DB record would defeat A/B testing if the strategy was
      # modified after the experiment started.
      OrchestrationStrategy.new(
        id: data["id"],
        strategy_type: data["strategy_type"] || fallback_strategy_type,
        name: data["name"] || fallback_strategy_type.to_s.titleize,
        version: data["version"] || 1,
        configuration: data.fetch("configuration") { raise ArgumentError, "snapshot missing 'configuration' for strategy #{data['strategy_type']}" },
        active: data.fetch("active", true),
        account: resolved_account(account, data["account_id"])
      )
    end

    def resolved_account(account, account_id)
      return account if account && account.id.to_s == account_id.to_s
      return unless account_id.present?

      Account.find_by(id: account_id)
    end
    private_class_method :resolved_account
  end
end
