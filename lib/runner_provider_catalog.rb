# frozen_string_literal: true

# Shared by application runners and CLI validation without loading Rails.
# @spec TEST-SUITE-010
module RunnerProviderCatalog
  DIRECT_OUTBOUND_API_PROVIDERS = {
    "openrouter" => { label: "OpenRouter", base_url: "https://openrouter.ai/api/v1", service_type: "openrouter",
                      opencode_model_provider: "openrouter" },
    "anthropic" => { label: "Anthropic", base_url: "https://api.anthropic.com", service_type: "anthropic",
                     opencode_npm: "@ai-sdk/anthropic", kilocode_provider_id: "anthropic",
                     opencode_model_provider: "anthropic" },
    "openai" => { label: "OpenAI", base_url: "https://api.openai.com/v1", service_type: "openai",
                  kilocode_provider_id: "openai", opencode_model_provider: "openai" },
    "inception" => { label: "InceptionLabs", base_url: "https://api.inceptionlabs.ai/v1", service_type: "inception",
                     kilocode_provider_id: "inception", opencode_model_provider: "inception" },
    "deepseek" => { label: "DeepSeek", base_url: "https://api.deepseek.com/v1", service_type: "deepseek",
                    opencode_model_provider: "deepseek" },
    "mistral" => { label: "Mistral", base_url: "https://api.mistral.ai/v1", service_type: "mistral",
                   opencode_model_provider: "mistral" },
    "minimax" => { label: "MiniMax", base_url: "https://api.minimax.io/anthropic/v1", chat_base_url: "https://api.minimax.io/v1", service_type: "minimax",
                   env_var: "ANTHROPIC_API_KEY", opencode_npm: "@ai-sdk/anthropic", kilocode_provider_id: "anthropic",
                   opencode_model_provider: "minimax" },
    "xai" => { label: "xAI", base_url: "https://api.x.ai/v1", service_type: "xai",
               opencode_model_provider: "xai" },
    "zai" => { label: "z.ai", base_url: "https://api.z.ai/api/paas/v4", service_type: "zai",
               opencode_model_provider: "zai", chat_max_tokens: 16_384 },
    # Both KiloCode and OpenCode ship a built-in "zai-coding-plan" provider
    # whose availability probe checks ZHIPU_API_KEY (not ZAI_CODING_API_KEY).
    # Override the auto-derived name so the key lands where the CLIs look.
    # opencode_model_provider matches the built-in provider id (hyphenated).
    # opencode_custom marks this as needing a declared model entry: opencode's
    # catalog tops out before glm-5.x, so opencode_runner_runtime extends the
    # built-in provider with the configured model instead of overriding it.
    "zai_coding" => { label: "z.ai (Coding Plan)", base_url: "https://api.z.ai/api/coding/paas/v4", service_type: "zai_coding",
                      env_var: "ZHIPU_API_KEY", kilocode_provider_id: "zai-coding-plan", opencode_model_provider: "zai-coding-plan",
                      opencode_custom: true, chat_max_tokens: 16_384 }
  }.freeze

  PI_API_PROVIDERS = {
    "anthropic" => { label: "Anthropic", service_type: "anthropic", env_var: "ANTHROPIC_API_KEY" },
    "openai" => { label: "OpenAI", service_type: "openai", env_var: "OPENAI_API_KEY" },
    "deepseek" => { label: "DeepSeek", service_type: "deepseek", env_var: "DEEPSEEK_API_KEY" },
    "google" => { label: "Google Gemini", service_type: "google", env_var: "GEMINI_API_KEY" },
    "mistral" => { label: "Mistral", service_type: "mistral", env_var: "MISTRAL_API_KEY" },
    "minimax" => { label: "MiniMax", service_type: "minimax", env_var: "ANTHROPIC_API_KEY" },
    "xai" => { label: "xAI", service_type: "xai", env_var: "XAI_API_KEY" },
    "zai" => { label: "z.ai", service_type: "zai", env_var: "ZAI_API_KEY" },
    "openrouter" => { label: "OpenRouter", service_type: "openrouter", env_var: "OPENROUTER_API_KEY" }
  }.freeze

  SERVICE_TYPE_ENV_VARS = {
    "anthropic" => "ANTHROPIC_API_KEY",
    "openai" => "OPENAI_API_KEY",
    "openrouter" => "OPENROUTER_API_KEY",
    "google" => "GOOGLE_API_KEY",
    "inception" => "INCEPTION_API_KEY",
    "deepseek" => "DEEPSEEK_API_KEY",
    "mistral" => "MISTRAL_API_KEY",
    "minimax" => "ANTHROPIC_API_KEY",
    "xai" => "XAI_API_KEY",
    "zai" => "ZAI_API_KEY",
    "zai_coding" => "ZHIPU_API_KEY"
  }.freeze

  OMP_API_PROVIDERS = PI_API_PROVIDERS
  ADHOC_MODEL_ENV = "PAID_SMOKE_ADHOC_MODEL"

  module_function

  def provider_configs_for_runner(runner_key)
    case runner_key.to_s
    when "opencode", "kilocode" then DIRECT_OUTBOUND_API_PROVIDERS
    when "pi" then PI_API_PROVIDERS
    when "omp" then OMP_API_PROVIDERS
    else {}
    end
  end

  def provider_config_for(runner_key:, api_provider:)
    provider_configs_for_runner(runner_key)[api_provider.to_s]
  end

  def api_key_env_var_for(runner_key:, api_provider:)
    config = provider_config_for(runner_key:, api_provider:)
    return unless config

    config[:env_var] || SERVICE_TYPE_ENV_VARS[config.fetch(:service_type)]
  end
end
