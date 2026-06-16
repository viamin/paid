# frozen_string_literal: true

FactoryBot.define do
  factory :dispatch_circuit_breaker do
    account
    circuit_state { "closed" }
    half_open_success_count { 0 }
    half_open_failure_count { 0 }
    trip_metadata { {} }

    trait :open do
      circuit_state { "open" }
      circuit_opened_at { Time.current }
      trip_metadata { { "failure_rate" => 0.9, "providers" => {} } }
    end

    trait :half_open do
      circuit_state { "half_open" }
      circuit_opened_at { 10.minutes.ago }
    end
  end
end
