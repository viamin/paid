# frozen_string_literal: true

module OrchestrationStrategies
  # Resolves the effective strategy configuration for a given type, with
  # account-level overrides falling back to system defaults, then to
  # hardcoded constants if no database record exists yet.
  #
  # This keeps runtime behavior identical during the migration period:
  # callers get the same configuration values whether they come from a
  # persisted strategy record or the legacy constants.
  class Resolve
    def self.call(...)
      new(...).call
    end

    def initialize(strategy_type:, account: nil)
      @strategy_type = strategy_type.to_s
      @account = account
    end

    def call
      OrchestrationStrategy.active_for(strategy_type, account: account) ||
        build_fallback
    end

    private

    attr_reader :strategy_type, :account

    def build_fallback
      config = Defaults.configuration_for(strategy_type)
      return nil unless config

      OrchestrationStrategy.new(
        strategy_type: strategy_type,
        name: "#{strategy_type.titleize} (hardcoded fallback)",
        version: 0,
        configuration: config,
        active: true,
        account: nil
      )
    end
  end
end
