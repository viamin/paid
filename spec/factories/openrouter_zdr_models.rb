# frozen_string_literal: true

FactoryBot.define do
  factory :openrouter_zdr_model do
    sequence(:model_id) { |n| "vendor/zdr-model-#{n}" }
    endpoint_count { 1 }
    endpoint_payloads { [ { "model_id" => model_id } ] }
    last_seen_at { Time.current }
  end
end
