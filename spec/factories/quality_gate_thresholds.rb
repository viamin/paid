# frozen_string_literal: true

FactoryBot.define do
  factory :quality_gate_threshold do
    project
    metric_key { "composite_score" }
    min_threshold { 0.5 }
    severity { "warning" }
    enabled { true }

    trait :critical do
      severity { "critical" }
      min_threshold { 0.3 }
    end

    trait :with_max do
      max_threshold { 0.95 }
    end

    trait :disabled do
      enabled { false }
    end
  end
end
