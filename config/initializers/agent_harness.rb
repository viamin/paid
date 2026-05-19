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
  # Derived lazily via a method so that Provider (an autoloaded model) is
  # guaranteed to be available regardless of initializer load order.
  def pi_api_key_env_vars = Provider::PI_API_PROVIDERS.values.map { |c| c[:env_var] }.freeze

  def api_key_env_var_names = pi_api_key_env_vars

  def subscription_unset_vars = pi_api_key_env_vars

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

# Backport embedding support until agent-harness ships a native public API.
# Keep this version-gated and narrow so Paid can switch back to upstream
# behavior cleanly once the gem exposes AgentHarness.embed (or equivalent).
# TODO(#2146): remove when agent-harness >= 0.19.0 ships native embeddings support
module PaidAgentHarnessEmbeddingTransportPatch
  def initialize(base_url:, api_key:, model:, logger: nil, extra_headers: {}, timeout: self.class::DEFAULT_TIMEOUT)
    @paid_extra_headers = extra_headers
    @paid_timeout = timeout
    super(base_url:, api_key:, model:, logger:)
  end

  def embed(inputs:, model: nil, dimensions: nil)
    uri = URI("#{@base_url}/embeddings")
    body = {
      input: inputs,
      model: model || @model
    }
    body[:dimensions] = dimensions if dimensions

    http_response = make_request(uri, body)
    status_code = http_response.code.to_i
    handle_embedding_error_response(http_response, status_code) unless status_code == 200

    JSON.parse(http_response.body)
  rescue JSON::ParserError => e
    raise AgentHarness::ProviderError.new(
      "Invalid JSON in embedding API response: #{e.message}",
      original_error: e
    )
  end

  private

  def build_http(uri)
    http = super
    http.read_timeout = @paid_timeout if @paid_timeout
    http
  end

  def build_post_request(uri, body)
    request = super
    @paid_extra_headers.each { |key, value| request[key] = value }
    request
  end

  def handle_embedding_error_response(http_response, status_code)
    headers = http_response.each_header.to_h.transform_keys(&:downcase)
    context = {
      status: status_code,
      headers: headers
    }
    message = embedding_error_message(http_response.body)

    case status_code
    when 401
      raise AgentHarness::AuthenticationError.new(
        "API authentication failed: #{message}",
        provider: :openai_compatible,
        context:
      )
    when 403
      raise AgentHarness::AuthenticationError.new(
        "API access forbidden: #{message}",
        provider: :openai_compatible,
        context:
      )
    when 429
      raise AgentHarness::RateLimitError.new(
        "API rate limit exceeded: #{message}",
        provider: :openai_compatible,
        context:
      )
    when 400
      raise AgentHarness::ProviderError.new("Bad request: #{message}", context:)
    when 500, 502, 503, 504
      raise AgentHarness::ProviderError.new("Server error (#{status_code}): #{message}", context:)
    else
      raise AgentHarness::ProviderError.new("HTTP #{status_code}: #{message}", context:)
    end
  end

  def embedding_error_message(body_string)
    body = JSON.parse(body_string)
    body.dig("error", "message") || body.dig("error", "type") || body_string
  rescue JSON::ParserError
    body_string
  end
end

module PaidAgentHarnessEmbeddingPatch
  def embed(inputs, model:, base_url:, api_key:, dimensions: nil, headers: {}, timeout: AgentHarness::OpenAICompatibleTransport::DEFAULT_TIMEOUT)
    transport = AgentHarness::OpenAICompatibleTransport.new(
      base_url: base_url,
      api_key: api_key,
      model: model,
      logger: logger,
      extra_headers: headers,
      timeout: timeout
    )

    transport.embed(
      inputs: Array(inputs),
      model: model,
      dimensions: dimensions
    )
  end
end

if agent_harness_version < Gem::Version.new("0.19.0") && !AgentHarness.respond_to?(:embed)
  AgentHarness::OpenAICompatibleTransport.prepend(PaidAgentHarnessEmbeddingTransportPatch) unless
    AgentHarness::OpenAICompatibleTransport < PaidAgentHarnessEmbeddingTransportPatch
  AgentHarness.extend(PaidAgentHarnessEmbeddingPatch)
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
