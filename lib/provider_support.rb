# frozen_string_literal: true

module ProviderSupport
  APP_TO_HARNESS_PROVIDER_KEYS = {
    "claude" => "claude",
    "cursor" => "cursor",
    "codex" => "codex",
    "copilot" => "github_copilot",
    "aider" => "aider",
    "gemini" => "gemini",
    "opencode" => "opencode",
    "kilocode" => "kilocode"
  }.freeze

  module_function

  def supported_provider_keys
    registry_keys = AgentHarness::Providers::Registry.instance.all.map(&:to_s)

    APP_TO_HARNESS_PROVIDER_KEYS.filter_map do |provider_key, harness_key|
      provider_key if registry_keys.include?(harness_key)
    end
  end

  def supported_provider_key?(provider_key)
    supported_provider_keys.include?(provider_key.to_s)
  end

  def harness_provider_key_for(provider_key)
    APP_TO_HARNESS_PROVIDER_KEYS.fetch(provider_key.to_s, provider_key.to_s)
  end

  def provider_key_for_agent_type(agent_type)
    return "claude" if agent_type.to_s == "claude_code"

    agent_type.to_s
  end

  def agent_type_for(provider_key)
    return "claude_code" if provider_key.to_s == "claude"

    provider_key.to_s
  end
end
