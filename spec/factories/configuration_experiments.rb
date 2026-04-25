# frozen_string_literal: true

FactoryBot.define do
  factory :configuration_experiment do
    account
    sequence(:name) { |n| "Configuration Experiment #{n}" }
    config_key { "knowledge.token_budget" }
    status { "draft" }
    control_value { JSON.generate(4000) }
    experiment_type { "agent_output" }
    min_samples_per_variant { 30 }
    confidence_threshold { 0.95 }
    traffic_percentage { 100 }
  end
end
