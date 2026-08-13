# frozen_string_literal: true

FactoryBot.define do
  factory :coordination_experiment_variant do
    coordination_experiment
    policy_config { OrchestrationStrategies::Defaults.feature_orchestration.deep_dup }
    is_control { false }
    sample_count { 0 }
    total_coordination_score { 0 }
  end
end
