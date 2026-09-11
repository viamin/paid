# frozen_string_literal: true

FactoryBot.define do
  factory :runner do
    user
    runner_key { "cursor" }
    auth_type { "subscription" }
    enabled_for_agent_runs { true }
    enabled_for_chat { true }
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

    after(:build) do |runner|
      if runner.runner_key == "opencode" &&
          runner.config.is_a?(Hash) &&
          runner.config.dig("opencode", "model_policy") == "free" &&
          runner.enabled_for_chat?
        runner.enabled_for_chat = false
      end

      KnownDirectOutboundModels.seed_from_direct_outbound_config(runner)
    end
  end
end
