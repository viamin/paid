# frozen_string_literal: true

FactoryBot.define do
  factory :coordination_experiment do
    account
    sequence(:name) { |n| "Coordination Experiment #{n}" }
    policy_name { CoordinationExperiment::POLICY_NAME }
    status { "running" }
    control_policy { OrchestrationStrategies::Defaults.feature_orchestration.deep_dup }
    min_samples_per_variant { 2 }
    traffic_percentage { 100 }
  end
end
