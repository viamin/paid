# frozen_string_literal: true

FactoryBot.define do
  factory :strategy_experiment_variant do
    strategy_experiment
    sequence(:strategy_config) { |n| JSON.generate("version" => "variant_#{n}") }
    is_control { false }
    sample_count { 0 }
    total_quality_score { 0 }
  end
end
