# frozen_string_literal: true

module StrategyExperiments
  class CreateForCandidates
    def self.call(...)
      new(...).call
    end

    def initialize(account:, strategy_type:, control_strategy:, candidate_strategies:, name: nil, description: nil, **options)
      @account = account
      @strategy_type = strategy_type.to_s
      @control_strategy = control_strategy
      @candidate_strategies = Array(candidate_strategies)
      @name = name
      @description = description
      @options = options
    end

    def call
      validate!

      StrategyExperiments::Create.call(
        account: account,
        name: name || default_name,
        description: description,
        strategy_name: strategy_type,
        control_config: StrategySnapshot.serialize(control_strategy),
        variant_configs: candidate_strategies.map { |strategy| StrategySnapshot.serialize(strategy) },
        **options
      )
    end

    private

    attr_reader :account, :strategy_type, :control_strategy, :candidate_strategies, :name, :description, :options

    def validate!
      raise ArgumentError, "control strategy is required" unless control_strategy
      raise ArgumentError, "at least one candidate strategy is required" if candidate_strategies.empty?
      raise ArgumentError, "candidate strategies must all match the experiment strategy type" unless matching_strategy_types?
    end

    def matching_strategy_types?
      candidate_strategies.all? { |strategy| strategy.strategy_type == strategy_type } &&
        control_strategy.strategy_type == strategy_type
    end

    def default_name
      "Strategy evolution #{strategy_type.tr('_', ' ')} #{Date.current}"
    end
  end
end
