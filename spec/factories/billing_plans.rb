# frozen_string_literal: true

FactoryBot.define do
  factory :billing_plan do
    account
    name { "Standard Plan" }
    billing_model { "per_token" }
    period_type { "monthly" }
    base_rate_cents { 0 }
    per_token_rate_cents { 0.003 }
    per_run_rate_cents { 0 }
    per_project_rate_cents { 0 }
    included_tokens { 1_000_000 }
    included_runs { 0 }
    included_projects { 0 }
    active { true }
    metadata { {} }

    trait :flat_rate do
      name { "Flat Rate Plan" }
      billing_model { "flat_rate" }
      base_rate_cents { 10_000 }
      per_token_rate_cents { 0 }
      included_tokens { 0 }
    end

    trait :per_run do
      name { "Per Run Plan" }
      billing_model { "per_run" }
      per_token_rate_cents { 0 }
      per_run_rate_cents { 500 }
      included_tokens { 0 }
      included_runs { 10 }
    end

    trait :per_project do
      name { "Per Project Plan" }
      billing_model { "per_project" }
      per_token_rate_cents { 0 }
      per_project_rate_cents { 5_000 }
      included_tokens { 0 }
      included_projects { 3 }
    end

    trait :inactive do
      active { false }
    end
  end
end
