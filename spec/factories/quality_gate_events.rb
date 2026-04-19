# frozen_string_literal: true

FactoryBot.define do
  factory :quality_gate_event do
    project
    quality_gate_threshold
    quality_metric
    event_type { "trigger" }
    score_value { 0.4 }
    threshold_value { 0.5 }
    metadata { { metric_key: "composite_score", severity: "warning" } }

    trait :recovery do
      event_type { "recovery" }
      score_value { 0.6 }
    end
  end
end
