# frozen_string_literal: true

require "agent_harness"

AgentHarness.configure do |config|
  config.default_provider = :claude
  config.fallback_providers = %i[cursor aider]
  config.default_timeout = ENV.fetch("AGENT_TIMEOUT", 600).to_i

  config.provider(:claude) do |p|
    p.enabled = true
    p.priority = 10
    p.timeout = ENV.fetch("AGENT_TIMEOUT", 600).to_i
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
