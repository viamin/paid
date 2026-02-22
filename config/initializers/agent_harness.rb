# frozen_string_literal: true

require "agent_harness"

parse_timeout = ->(env_key, default) do
  [ Integer(ENV.fetch(env_key, default)), 1 ].max
rescue ArgumentError
  Rails.logger.warn(message: "agent_harness.invalid_timeout",
    env_key: env_key,
    value: ENV[env_key],
    fallback: default)
  default
end

Rails.application.config.x.agent_timeout = parse_timeout.call("AGENT_TIMEOUT", 1800)
Rails.application.config.x.agent_startup_timeout = parse_timeout.call("AGENT_STARTUP_TIMEOUT", 300)
Rails.application.config.x.agent_idle_timeout = parse_timeout.call("AGENT_IDLE_TIMEOUT", 300)
Rails.application.config.x.agent_execution_budget = parse_timeout.call("AGENT_EXECUTION_BUDGET", 3600)

AgentHarness.configure do |config|
  config.default_provider = :claude
  config.fallback_providers = %i[cursor aider]
  config.default_timeout = Rails.application.config.x.agent_timeout

  config.provider(:claude) do |p|
    p.enabled = true
    p.priority = 10
    p.timeout = Rails.application.config.x.agent_timeout
  end

  config.provider(:cursor) do |p|
    p.enabled = ENV.fetch("CURSOR_ENABLED", "false") == "true"
    p.priority = 20
  end

  config.provider(:aider) do |p|
    p.enabled = ENV.fetch("AIDER_ENABLED", "false") == "true"
    p.priority = 30
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
