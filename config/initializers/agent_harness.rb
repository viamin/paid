# frozen_string_literal: true

require Rails.root.join("lib/provider_support").to_s

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
  def smoke_test(timeout:, provider_runtime:)
    super(
      timeout: effective_smoke_test_timeout(timeout),
      provider_runtime: provider_runtime
    )
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

  def perform_check(provider_name, start_time, timeout:, executor:, provider_runtime:)
    previous_timeout = Thread.current[:paid_agent_harness_smoke_test_timeout]
    Thread.current[:paid_agent_harness_smoke_test_timeout] = timeout
    super
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
if agent_harness_version < Gem::Version.new("0.18.0")
  AgentHarness::ProviderHealthCheck.singleton_class.prepend(AgentHarnessSmokeTestTimeoutPatch)
end

# Default agent timeout used for AgentHarness boot-time config and as a
# fallback when per-user settings are unavailable. Runtime code should
# prefer UserSetting#agent_timeout_seconds resolved via
# AgentRuns::UserSettingsResolver.
AGENT_TIMEOUT_DEFAULT = 3600
Rails.application.config.x.agent_timeout = AGENT_TIMEOUT_DEFAULT

AgentHarness.configure do |config|
  # Order is deterministic: follows APP_PROVIDER_KEYS declaration order.
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

      # Tell the harness that container-executed providers are externally
      # sandboxed so provider-specific nested sandbox mechanisms (e.g.
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
