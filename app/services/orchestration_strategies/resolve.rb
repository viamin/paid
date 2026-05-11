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

    def initialize(strategy_type:, account: nil, agent_run: nil)
      @strategy_type = strategy_type.to_s
      @account = account
      @agent_run = agent_run
    end

    def call
      experiment_strategy || persisted_or_fallback_strategy
    end

    private

    attr_reader :strategy_type, :account, :agent_run

    def experiment_strategy
      experiment = active_experiment
      return unless experiment

      assignment = StrategyExperiments::Assign.call(
        strategy_experiment: experiment,
        agent_run: agent_run
      )

      StrategyExperiments::StrategySnapshot.deserialize(
        assignment.strategy_experiment_variant.parsed_config,
        account: account,
        fallback_strategy_type: strategy_type
      )
    end

    def active_experiment
      return unless account && agent_run

      StrategyExperiment.active_for(strategy_type, account: account, agent_run: agent_run)
    end

    def persisted_or_fallback_strategy
      OrchestrationStrategy.active_for(strategy_type, account: account) ||
        build_fallback
    end

    def build_fallback
      config = Defaults.configuration_for(strategy_type)
      return nil unless config

      OrchestrationStrategy.new(
        strategy_type: strategy_type,
        name: "#{strategy_type.titleize} (hardcoded fallback)",
        version: 1,
        configuration: config,
        active: true,
        account: nil
      )
    end
  end
end
