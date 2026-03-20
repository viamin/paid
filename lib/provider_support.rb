# frozen_string_literal: true

require "set"

module ProviderSupport
  # Maps app-level provider keys to agent-harness registry keys.
  # This drives validation, UI, and configuration — providers listed here are
  # "known" to the app and can be configured by users.
  #
  # NOTE: Inclusion here does NOT mean the provider's CLI is installed in the
  # agent Docker container. For container execution, see CONTAINER_EXECUTABLE_PROVIDER_KEYS.
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

  # Provider keys whose CLIs are actually installed in the agent Docker container
  # (docker/agent/Dockerfile). Only these providers can execute in container-based
  # runs. Currently only the Claude CLI is installed in the container image.
  # Update this list when new CLIs are added to the Dockerfile.
  CONTAINER_EXECUTABLE_PROVIDER_KEYS = Set.new(%w[claude]).freeze

  module_function

  # Returns supported provider keys in a deterministic order matching
  # APP_TO_HARNESS_PROVIDER_KEYS declaration order, so that provider
  # priority and default selection are stable across boots.
  def supported_provider_keys
    APP_TO_HARNESS_PROVIDER_KEYS.keys.select { |key| supported_provider_keys_set.include?(key) }
  end

  def supported_provider_key?(provider_key)
    supported_provider_keys_set.include?(provider_key.to_s)
  end

  def supported_provider_keys_set
    @supported_provider_keys_set ||= begin
      registry_keys = AgentHarness::Providers::Registry.instance.all.map(&:to_s).to_set

      APP_TO_HARNESS_PROVIDER_KEYS.each_with_object(Set.new) do |(provider_key, harness_key), set|
        set << provider_key if registry_keys.include?(harness_key)
      end.freeze
    end
  end

  def reset_supported_provider_keys!
    @supported_provider_keys_set = nil
  end

  def container_executable_provider_keys
    supported_provider_keys.select { |key| CONTAINER_EXECUTABLE_PROVIDER_KEYS.include?(key) }
  end

  def container_executable_provider_key?(provider_key)
    container_executable_provider_keys.include?(provider_key.to_s)
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
