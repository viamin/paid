# frozen_string_literal: true

FactoryBot.define do
  factory :configuration_experiment_variant do
    configuration_experiment
    sequence(:config_value) { |n| JSON.generate(4000 + n) }
    is_control { false }
    sample_count { 0 }
    total_quality_score { 0 }
  end
end
