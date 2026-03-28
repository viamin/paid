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
      fallback_role { "rate_limit_fallback" }
    end
  end
end
