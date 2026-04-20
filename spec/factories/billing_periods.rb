# frozen_string_literal: true

FactoryBot.define do
  factory :billing_period do
    account
    billing_plan { association(:billing_plan, account: account) }
    period_type { "monthly" }
    starts_at { Time.current.beginning_of_month }
    ends_at { Time.current.end_of_month }
    status { "open" }
    total_cost_cents { 0 }
    total_input_tokens { 0 }
    total_output_tokens { 0 }
    total_runs { 0 }
    total_compute_seconds { 0 }
    metadata { {} }

    trait :closed do
      status { "closed" }
    end

    trait :invoiced do
      status { "invoiced" }
    end

    trait :with_usage do
      total_cost_cents { 5_000 }
      total_input_tokens { 500_000 }
      total_output_tokens { 250_000 }
      total_runs { 15 }
      total_compute_seconds { 3600 }
    end
  end
end
