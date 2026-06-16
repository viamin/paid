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

      known_models = {
        [ "openrouter", "moonshotai/kimi-k2-0905" ] => "openrouter",
        [ "openrouter", "moonshotai/kimi-k2.5" ] => "openrouter",
        [ "openrouter", "moonshotai/kimi-k2" ] => "openrouter",
        [ "openrouter", "moonshotai/kimi-k2-0906" ] => "openrouter",
        [ "anthropic", "claude-sonnet-4-20250514" ] => "anthropic",
        [ "anthropic", "claude-sonnet-4-5" ] => "anthropic",
        [ "anthropic", "claude-3-7-sonnet" ] => "anthropic",
        [ "anthropic", "anthropic/claude-opus-4" ] => "anthropic",
        [ "openai", "gpt-4o" ] => "openai",
        [ "openai", "gpt-5.5" ] => "openai",
        [ "inception", "mercury-2" ] => "inception",
        [ "deepseek", "deepseek-chat" ] => "deepseek",
        [ "minimax", "MiniMax-M2.7" ] => "minimax",
        [ "minimax", "MiniMax-M2.7-highspeed" ] => "minimax",
        [ "zai_coding", "glm-5.1" ] => "zai_coding",
        [ "zai", "glm-5.1" ] => "zai"
      }

      provider = known_models[[ api_provider, model_id ]]
      next if provider.blank?

      LlmModel.find_or_create_by!(model_id: model_id) do |model|
        model.display_name = model_id.split("/").last.tr("_-", " ").split.map(&:capitalize).join(" ")
        model.provider = provider
        model.category = "coding"
        model.tier = "mid"
        model.active = true
      end
    end
  end
end
