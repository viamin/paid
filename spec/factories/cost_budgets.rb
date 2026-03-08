# frozen_string_literal: true

FactoryBot.define do
  factory :cost_budget do
    project
    budget_type { "monthly" }
    limit_cents { 100_000 }
    current_usage_cents { 0 }
    alert_threshold_percent { 80 }

    trait :daily do
      budget_type { "daily" }
      limit_cents { 5_000 }
    end

    trait :per_run do
      budget_type { "per_run" }
      limit_cents { 1_000 }
    end

    trait :near_limit do
      current_usage_cents { 85_000 }
    end

    trait :exceeded do
      current_usage_cents { 100_001 }
    end
  end
end
