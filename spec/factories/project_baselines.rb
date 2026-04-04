# frozen_string_literal: true

FactoryBot.define do
  factory :project_baseline do
    project
    metric_name { "tokens_total" }
    mean { 15000.0 }
    standard_deviation { 5000.0 }
    p95 { 25000.0 }
    sample_count { 20 }
    last_calculated_at { Time.current }
  end
end
