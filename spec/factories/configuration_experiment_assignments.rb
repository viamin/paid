# frozen_string_literal: true

FactoryBot.define do
  factory :configuration_experiment_assignment do
    configuration_experiment
    configuration_experiment_variant do
      association :configuration_experiment_variant, configuration_experiment: configuration_experiment, strategy: :create
    end
    agent_run { association :agent_run, strategy: :create }
  end
end
