# frozen_string_literal: true

FactoryBot.define do
  factory :strategy_experiment do
    account
    sequence(:name) { |n| "Strategy Experiment #{n}" }
    strategy_name { "auto_review" }
    status { "draft" }
    control_config { JSON.generate("version" => "baseline") }
    min_samples_per_variant { 30 }
    confidence_threshold { 0.95 }
    traffic_percentage { 100 }
  end
end
