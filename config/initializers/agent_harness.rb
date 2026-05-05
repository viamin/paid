# frozen_string_literal: true

require Rails.root.join("lib/provider_support").to_s

# Backport fix for viamin/agent-harness#173 — the gem's
# ProviderHealthCheck.perform_check passes `nil` as the smoke-test timeout
# when a contract exists, so the adapter falls back to the contract's 30s
# default. Slow models (e.g. Kilocode GLM 5.1) need the caller-specified
# timeout honoured. This patch forwards `max(caller_timeout, contract_timeout)`
# instead of nil. Remove once agent-harness >= 0.18 ships the fix.
# TODO(#1538): remove this monkey-patch when agent-harness ships the upstream fix
module AgentHarnessSmokeTestTimeoutPatch
  private

  def perform_check(provider_name, start_time, timeout:, executor:, provider_runtime:)
    registry = AgentHarness::Providers::Registry.instance
    unless registry.registered?(provider_name)
      return build_result(
        name: provider_name,
        status: "error",
        message: "Provider not registered",
        start_time: start_time,
        error_category: :installation,
        check: :registration
      )
    end

    klass = registry.get(provider_name)
    provider_instance = build_provider(provider_name, klass, executor: executor)
    host_preflight_allowed = host_preflight_allowed?(executor: executor, provider_runtime: provider_runtime)
    provider_preflight_allowed = provider_preflight_allowed?(executor: executor)

    auth_degraded = false
    if host_preflight_allowed
      if executor.nil? && !klass.available?
        return build_result(
          name: provider_name,
          status: "error",
          message: "Provider '#{klass.binary_name}' is not available (#{klass}.available? returned false)",
          start_time: start_time,
          error_category: :installation,
          check: :availability
        )
      end

      unless provider_instance.executor.which(klass.binary_name)
        return build_result(
          name: provider_name,
          status: "error",
          message: "CLI '#{klass.binary_name}' not found in PATH",
          start_time: start_time,
          error_category: :installation,
          check: :availability
        )
      end

      auth = AgentHarness::Authentication.auth_status(provider_name)
      unless auth[:valid]
        unless auth_not_implemented?(auth)
          return build_result(
            name: provider_name,
            status: "error",
            message: auth[:error] || "Authentication failed",
            start_time: start_time,
            error_category: :authentication,
            check: :authentication
          )
        end
        auth_degraded = true
      end

      health = provider_instance.health_status
      unless health[:healthy]
        return build_result(
          name: provider_name,
          status: "degraded",
          message: health[:message] || "Provider health check failed",
          start_time: start_time,
          error_category: :transient,
          check: :provider_health
        )
      end
    end

    validation = provider_instance.validate_config
    unless validation[:valid]
      errors_msg = Array(validation[:errors]).join(", ")
      errors_msg = "check provider configuration" if errors_msg.empty?
      return build_result(
        name: provider_name,
        status: "degraded",
        message: "Configuration issues: #{errors_msg}",
        start_time: start_time,
        error_category: :configuration,
        check: :configuration
      )
    end

    if provider_preflight_allowed
      preflight_env = build_preflight_env(provider_instance, provider_runtime)
      preflight = provider_instance.preflight_check(env: preflight_env, timeout: timeout)
      unless preflight[:healthy]
        return build_result(
          name: provider_name,
          status: "error",
          message: preflight[:reason] || "Preflight check failed",
          start_time: start_time,
          error_category: normalize_preflight_error_category(preflight[:error_category]),
          check: :preflight
        )
      end
    end

    smoke_contract = provider_instance.smoke_test_contract
    if smoke_contract.nil? && !provider_overrides_method?(provider_instance, :smoke_test)
      message = if host_preflight_allowed && auth_degraded
        "Auth status check not implemented; health and config checks passed (smoke test unavailable)"
      elsif host_preflight_allowed && (provider_overrides_method?(provider_instance, :health_status) ||
        provider_overrides_method?(provider_instance, :validate_config))
        "Health and config checks passed (smoke test unavailable)"
      elsif host_preflight_allowed
        "Registered and authenticated; health/config checks use defaults and smoke test is unavailable"
      elsif provider_overrides_method?(provider_instance, :validate_config)
        "Configuration checks passed, but smoke test is unavailable for the supplied execution context"
      else
        "Smoke test is unavailable for the supplied execution context"
      end

      return build_result(
        name: provider_name,
        status: "degraded",
        message: message,
        start_time: start_time,
        error_category: :configuration,
        check: :smoke_test
      )
    end

    # --- PATCHED: pass max(caller_timeout, contract_timeout) instead of nil ---
    smoke_timeout = if smoke_contract
      contract_timeout = smoke_contract[:timeout]
      if timeout.is_a?(Numeric) && contract_timeout.is_a?(Numeric)
        [ timeout, contract_timeout ].max
      else
        timeout || contract_timeout
      end
    else
      timeout
    end
    smoke = provider_instance.smoke_test(timeout: smoke_timeout, provider_runtime: provider_runtime)
    unless smoke[:ok]
      return build_result(
        name: provider_name,
        status: smoke[:status] || "error",
        message: smoke[:message] || "Smoke test failed",
        start_time: start_time,
        error_category: normalize_smoke_error_category(smoke[:error_category], smoke[:message]),
        check: :smoke_test
      )
    end

    if auth_degraded
      return build_result(
        name: provider_name,
        status: "degraded",
        message: "Auth status check not implemented; health, config, and smoke tests passed",
        start_time: start_time,
        error_category: :authentication,
        check: :authentication
      )
    end

    message = if !host_preflight_allowed && provider_overrides_method?(provider_instance, :validate_config)
      "Configuration and smoke test passed using the supplied execution context"
    elsif !host_preflight_allowed
      "Smoke test passed using the supplied execution context"
    elsif provider_overrides_method?(provider_instance, :health_status) ||
        provider_overrides_method?(provider_instance, :validate_config)
      "All checks passed"
    else
      "Registered, authenticated, and smoke test passed (health/config checks use defaults)"
    end

    build_result(
      name: provider_name,
      status: "ok",
      message: message,
      start_time: start_time,
      check: :smoke_test
    )
  end
end

AgentHarness::ProviderHealthCheck.singleton_class.prepend(AgentHarnessSmokeTestTimeoutPatch)

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
