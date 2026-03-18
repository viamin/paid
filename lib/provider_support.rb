# frozen_string_literal: true

require "set"

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
    supported_provider_keys_set.to_a
  end

  def supported_provider_key?(provider_key)
    supported_provider_keys_set.include?(provider_key.to_s)
  end

  def supported_provider_keys_set
    @supported_provider_keys_set ||= begin
      registry_keys = AgentHarness::Providers::Registry.instance.all.map(&:to_s).to_set

      APP_TO_HARNESS_PROVIDER_KEYS.each_with_object(Set.new) do |(provider_key, harness_key), set|
        set << provider_key if registry_keys.include?(harness_key)
      end
    end
  end

  def reset_supported_provider_keys!
    @supported_provider_keys_set = nil
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
