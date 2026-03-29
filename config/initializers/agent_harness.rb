# frozen_string_literal: true

require "agent_harness"
require Rails.root.join("lib/provider_support").to_s

# Compatibility shim: ensure AuthenticationError exists for agent-harness
# versions older than 0.4.0 that may not define it.
if defined?(AgentHarness::Error) && !defined?(AgentHarness::AuthenticationError)
  AgentHarness::AuthenticationError = Class.new(AgentHarness::Error)
end

# Default agent timeout used for AgentHarness boot-time config and as a
# fallback when per-user settings are unavailable. Runtime code should
# prefer UserSetting#agent_timeout_seconds resolved via
# AgentRuns::UserSettingsResolver.
AGENT_TIMEOUT_DEFAULT = 3600
Rails.application.config.x.agent_timeout = AGENT_TIMEOUT_DEFAULT

AgentHarness.configure do |config|
  # Order is deterministic: follows APP_TO_HARNESS_PROVIDER_KEYS declaration order.
  supported_provider_keys = ProviderSupport.supported_provider_keys

  default_key = if supported_provider_keys.include?("claude")
    :claude
  elsif supported_provider_keys.any?
    ProviderSupport.harness_provider_key_for(supported_provider_keys.first).to_sym
  end

  config.default_provider = default_key if default_key
  config.fallback_providers = %w[cursor aider].filter_map do |provider_key|
    next unless supported_provider_keys.include?(provider_key)

    harness_provider_key = ProviderSupport.harness_provider_key_for(provider_key).to_sym
    next if default_key && harness_provider_key == default_key

    harness_provider_key
  end
  config.default_timeout = AGENT_TIMEOUT_DEFAULT

  supported_provider_keys.each_with_index do |provider_key, index|
    harness_provider_key = ProviderSupport.harness_provider_key_for(provider_key).to_sym

    config.provider(harness_provider_key) do |provider|
      provider.enabled = true
      provider.priority = (index + 1) * 10
      provider.timeout = AGENT_TIMEOUT_DEFAULT if harness_provider_key == :claude

      # Forward container execution flags (e.g. sandbox bypass) to the harness
      # so its command builder matches the container runtime behaviour.
      # TODO(viamin/agent-harness#48): Remove once the harness handles
      # container sandbox mode natively.
      container_flags = ProviderSupport.container_execution_flags_for(provider_key)
      provider.default_flags = container_flags if container_flags.any?
    end
  end

  config.orchestration do |orch|
    orch.enabled = true
    orch.auto_switch_on_error = true
    orch.auto_switch_on_rate_limit = true

    orch.circuit_breaker do |cb|
      cb.enabled = true
      cb.failure_threshold = 5
      cb.timeout = 300
    end

    orch.retry do |r|
      r.enabled = true
      r.max_attempts = 3
      r.base_delay = 1.0
      r.max_delay = 60.0
    end
  end

  config.logger = Rails.logger
end
