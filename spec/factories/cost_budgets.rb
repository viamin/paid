# frozen_string_literal: true

FactoryBot.define do
  factory :cost_budget do
    project
    budget_type { "monthly" }
    limit_cents { 100_000 }
    current_usage_cents { 0 }
    alert_threshold_percent { 80 }
    enforcement_mode { "alert" }
    grace_buffer_percent { 0 }
    period_started_at { Time.current.beginning_of_month }

    trait :daily do
      budget_type { "daily" }
      limit_cents { 5_000 }
      period_started_at { Time.current.beginning_of_day }
    end

    trait :per_run do
      budget_type { "per_run" }
      limit_cents { 1_000 }
      period_started_at { Time.current }
    end

    trait :near_limit do
      current_usage_cents { 85_000 }
    end

    trait :exceeded do
      current_usage_cents { 100_001 }
    end

    trait :hard_stop do
      enforcement_mode { "hard_stop" }
    end

    trait :with_grace_buffer do
      grace_buffer_percent { 10 }
    end
  end
end
