# frozen_string_literal: true

require "agent_harness"
require Rails.root.join("lib/provider_support")

agent_timeout = begin
  [ Integer(ENV.fetch("AGENT_TIMEOUT", 3600)), 1 ].max
rescue ArgumentError
  Rails.logger.warn(message: "agent_harness.invalid_timeout",
    value: ENV["AGENT_TIMEOUT"],
    fallback: 3600)
  3600
end

Rails.application.config.x.agent_timeout = agent_timeout

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

    ProviderSupport.harness_provider_key_for(provider_key).to_sym
  end
  config.default_timeout = Rails.application.config.x.agent_timeout

  supported_provider_keys.each_with_index do |provider_key, index|
    harness_provider_key = ProviderSupport.harness_provider_key_for(provider_key).to_sym

    config.provider(harness_provider_key) do |provider|
      provider.enabled = true
      provider.priority = (index + 1) * 10
      provider.timeout = Rails.application.config.x.agent_timeout if harness_provider_key == :claude
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
