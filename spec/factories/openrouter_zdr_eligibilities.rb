# frozen_string_literal: true

FactoryBot.define do
  factory :openrouter_zdr_eligibility do
    sequence(:model_id) { |n| "openrouter/zdr-model-#{n}" }
    endpoint_metadata { [] }
    endpoint_count { 1 }
    active { true }
    last_seen_at { Time.current }
  end
end
