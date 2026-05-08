# frozen_string_literal: true

FactoryBot.define do
  factory :strategy_experiment_assignment do
    strategy_experiment
    strategy_experiment_variant do
      association :strategy_experiment_variant, strategy_experiment: strategy_experiment, strategy: :create
    end
    agent_run { association :agent_run, strategy: :create }
  end
end
