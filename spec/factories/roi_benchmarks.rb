# frozen_string_literal: true

FactoryBot.define do
  factory :roi_benchmark do
    project
    name { "Human-only baseline" }
    benchmark_type { "human_only" }
    starts_at { 30.days.ago }
    ends_at { Time.current }
    merge_rate { 45.0 }
    average_cycle_time_hours { 72.0 }
    rework_rate { 28.0 }
    defect_escape_rate { 9.0 }
    cost_per_accepted_pr_cents { 18_000 }
    accepted_pr_count { 8 }
    notes { "Captured from a matched manual cohort." }

    trait :commercial_agent do
      name { "Commercial agent baseline" }
      benchmark_type { "commercial_agent" }
      tool_name { "Cursor" }
    end
  end
end
