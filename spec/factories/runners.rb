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
      config_key, api_provider_key, model_key = case runner.runner_key
      when "opencode" then [ "opencode", "api_provider", "model" ]
      when "kilocode" then [ "kilocode", "api_provider", "model" ]
      when "pi" then [ "pi", "api_provider", "model" ]
      else next
      end

      config = runner.config.is_a?(Hash) ? runner.config[config_key] : nil
      next unless config.is_a?(Hash)

      api_provider = config[api_provider_key].to_s
      model_id = config[model_key].to_s
      next if api_provider.blank? || model_id.blank?

      KnownDirectOutboundModels.seed_catalog_model(api_provider: api_provider, model_id: model_id)
    end
  end
end
