# frozen_string_literal: true

FactoryBot.define do
  factory :provider_api_key do
    user
    sequence(:name) { |n| "API Key #{n}" }
    api_key { "sk-test-#{SecureRandom.hex(16)}" }
    compatible_providers { %w[openrouter] }
  end
end
