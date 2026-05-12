# frozen_string_literal: true

require Rails.root.join("lib/runner_support").to_s

# Backport fix for viamin/agent-harness#173 — agent-harness 0.17.x passes
# `nil` as the smoke-test timeout when a contract exists, so the adapter
# falls back to the contract's 30s default. Slow models (e.g. Kilocode
# GLM 5.1) need the caller-specified timeout honoured.
#
# Keep this patch narrow and version-gated: only intercept the nil timeout
# forwarded into the provider smoke test, and only until agent-harness 0.18
# ships the upstream fix.
# TODO(#1538): remove this monkey-patch when agent-harness ships the upstream fix
module AgentHarnessSmokeTestTimeoutProviderPatch
  def smoke_test(*args, **kwargs, &block)
    if kwargs.key?(:timeout)
      kwargs = kwargs.merge(timeout: effective_smoke_test_timeout(kwargs[:timeout]))
    end

    super(*args, **kwargs, &block)
  end

  private

  def effective_smoke_test_timeout(timeout)
    return timeout unless timeout.nil?

    caller_timeout = instance_variable_get(:@paid_smoke_test_timeout)
    contract_timeout = smoke_test_contract&.dig(:timeout)

    if caller_timeout.is_a?(Numeric) && contract_timeout.is_a?(Numeric)
      [ caller_timeout, contract_timeout ].max
    else
      caller_timeout || contract_timeout
    end
  end
end

module AgentHarnessSmokeTestTimeoutPatch
  private

  def perform_check(*args, timeout: nil, **kwargs, &block)
    previous_timeout = Thread.current[:paid_agent_harness_smoke_test_timeout]
    Thread.current[:paid_agent_harness_smoke_test_timeout] = timeout
    super(*args, timeout: timeout, **kwargs, &block)
  ensure
    Thread.current[:paid_agent_harness_smoke_test_timeout] = previous_timeout
  end

  def build_provider(provider_name, klass, executor:)
    provider_instance = super
    provider_instance.instance_variable_set(
      :@paid_smoke_test_timeout,
      Thread.current[:paid_agent_harness_smoke_test_timeout]
    )
    provider_instance.singleton_class.prepend(AgentHarnessSmokeTestTimeoutProviderPatch) unless
      provider_instance.singleton_class < AgentHarnessSmokeTestTimeoutProviderPatch
    provider_instance
  end
end

agent_harness_version = Gem.loaded_specs.fetch("agent-harness").version
if agent_harness_version == Gem::Version.new("0.17.0")
  AgentHarness::ProviderHealthCheck.singleton_class.prepend(AgentHarnessSmokeTestTimeoutPatch)
end

# Default agent timeout used for AgentHarness boot-time config and as a
# fallback when per-user settings are unavailable. Runtime code should
# prefer UserSetting#agent_timeout_seconds resolved via
# AgentRuns::UserSettingsResolver.
AGENT_TIMEOUT_DEFAULT = 3600
Rails.application.config.x.agent_timeout = AGENT_TIMEOUT_DEFAULT

AgentHarness.configure do |config|
  # Order is deterministic: follows APP_RUNNER_KEYS declaration order.
  supported_runner_keys = RunnerSupport.supported_runner_keys

  default_key = if supported_runner_keys.include?("claude")
    :claude
  elsif supported_runner_keys.any?
    RunnerSupport.harness_runner_key_for(supported_runner_keys.first).to_sym
  end

  config.default_provider = default_key if default_key
  config.fallback_providers = %w[cursor aider].filter_map do |runner_key|
    next unless supported_runner_keys.include?(runner_key)

    harness_runner_key = RunnerSupport.harness_runner_key_for(runner_key).to_sym
    next if default_key && harness_runner_key == default_key

    harness_runner_key
  end
  config.default_timeout = AGENT_TIMEOUT_DEFAULT

  supported_runner_keys.each_with_index do |runner_key, index|
    harness_runner_key = RunnerSupport.harness_runner_key_for(runner_key).to_sym

    config.provider(harness_runner_key) do |provider|
      provider.enabled = true
      provider.priority = (index + 1) * 10
      provider.timeout = AGENT_TIMEOUT_DEFAULT if harness_runner_key == :claude

      # Tell the harness that container-executed runners are externally
      # sandboxed so runner-specific nested sandbox mechanisms (e.g.
      # Codex bubblewrap) are bypassed automatically.
      provider.externally_sandboxed = true
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
