# frozen_string_literal: true

require "agent_harness"

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
  config.default_provider = :claude
  config.fallback_providers = %i[cursor aider]
  config.default_timeout = Rails.application.config.x.agent_timeout

  AgentHarness::Providers::Registry.instance.all.each_with_index do |provider_name, index|
    config.provider(provider_name) do |provider|
      provider.enabled = true
      provider.priority = (index + 1) * 10
      provider.timeout = Rails.application.config.x.agent_timeout if provider_name == :claude
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
