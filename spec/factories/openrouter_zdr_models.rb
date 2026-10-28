# frozen_string_literal: true

FactoryBot.define do
  factory :openrouter_zdr_model do
    sequence(:model_id) { |n| "openrouter/zdr-model-#{n}" }
    metadata { {} }
    active { true }
    last_verified_at { Time.current }
  end
end
