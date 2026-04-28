# frozen_string_literal: true

FactoryBot.define do
  factory :github_health_state do
    endpoint { "api" }
    circuit_state { "closed" }
    failure_count { 0 }

    trait :circuit_open do
      circuit_state { "open" }
      failure_count { 5 }
      circuit_opened_at { Time.current }
    end

    trait :circuit_half_open do
      circuit_state { "half_open" }
      failure_count { 5 }
      circuit_opened_at { 10.minutes.ago }
    end
  end
end
