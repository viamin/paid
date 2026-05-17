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

# Backport Pi API-key runtime support that agent-harness 0.18.1 does not yet
# expose consistently. Pi itself supports API keys via env vars or auth.json,
# but its harness adapter still reports oauth-only auth semantics and does not
# materialize request-scoped auth.json content from ProviderRuntime metadata.
#
# Paid uses this patch to:
# - advertise the API-key env vars that subscription runs must unset
# - write a minimal ~/.pi/agent/auth.json for request-scoped API-key entries so
#   Pi's own auth precedence cannot pick a stale local credential instead
# - keep credentials off the command line (Pi supports --api-key, but that
#   would leak raw secrets via process args/logging)
module PaidAgentHarnessPiRuntimePatch
  PI_API_KEY_ENV_VARS = %w[
    ANTHROPIC_API_KEY
    OPENAI_API_KEY
    DEEPSEEK_API_KEY
    GEMINI_API_KEY
    MISTRAL_API_KEY
    XAI_API_KEY
    ZAI_API_KEY
    OPENROUTER_API_KEY
  ].freeze

  def api_key_env_var_names = PI_API_KEY_ENV_VARS

  def subscription_unset_vars = PI_API_KEY_ENV_VARS

  protected

  def build_execution_preparation(options)
    base = super
    runtime = options[:provider_runtime]
    auth_entry = runtime&.metadata&.dig("paid_pi_auth_entry")
    return base unless auth_entry.is_a?(Hash)

    provider = auth_entry["provider"].to_s.strip
    api_key = auth_entry["api_key"].to_s
    return base if provider.empty? || api_key.empty?

    auth_json = JSON.generate(
      provider => {
        type: "api_key",
        key: api_key
      }
    )

    pi_auth = AgentHarness::ExecutionPreparation.new(
      file_writes: [
        {
          path: "/home/agent/.pi/agent/auth.json",
          content: auth_json,
          mode: 0o600
        }
      ]
    )

    merge_execution_preparations(base, pi_auth)
  end

  private

  def merge_execution_preparations(base, extra)
    return extra if base.nil?
    return base if extra.nil?

    AgentHarness::ExecutionPreparation.new(file_writes: base.file_writes + extra.file_writes)
  end
end

# Drop this patch once agent-harness natively materialises Pi API-key auth.
# Adjust the version ceiling to whichever harness release ships that support.
# TODO(#2077): remove when agent-harness >= 0.19.0 ships native Pi API-key support
if agent_harness_version < Gem::Version.new("0.19.0")
  AgentHarness::Providers::Pi.prepend(PaidAgentHarnessPiRuntimePatch) unless
    AgentHarness::Providers::Pi < PaidAgentHarnessPiRuntimePatch
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
