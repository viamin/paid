# frozen_string_literal: true

FactoryBot.define do
  factory :provider do
    user
    provider_key { "cursor" }
    auth_type { "subscription" }
    enabled_for_agent_runs { true }
    enabled_for_fallback { true }
    fallback_role { "standard" }
    config { {} }

    trait :api_key do
      auth_type { "api_key" }
      provider_api_key
    end

    trait :rate_limit_fallback do
      auth_type { "api_key" }
      provider_api_key
      fallback_role { "rate_limit_fallback" }
    end

    after(:build) { |provider| KnownDirectOutboundModels.seed_from_direct_outbound_config(provider) }
  end
end
