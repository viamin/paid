# frozen_string_literal: true

require "digest"
require Rails.root.join("lib/runner_support").to_s

agent_harness_version = Gem.loaded_specs.fetch("agent-harness").version

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
# NOTE: 0.19.0 and 0.20.0 do NOT ship native Pi API-key auth.json
# materialization — build_execution_preparation still returns nil for Pi, so
# this backport must stay active. The ceiling was bumped from 0.19.0 to 0.21.0
# after the 0.20.0 bump (#2440) silently disabled it and broke every Pi
# API-key runner with "No API key found for <provider>".
# TODO(#2077): remove (and re-check this ceiling) when agent-harness ships
# native Pi API-key support.
if agent_harness_version < Gem::Version.new("0.21.0")
  AgentHarness::Providers::Pi.prepend(PaidAgentHarnessPiRuntimePatch) unless
    AgentHarness::Providers::Pi < PaidAgentHarnessPiRuntimePatch
end

# Route every explicit Claude MCP config through ExecutionPreparation so the file
# is written inside the agent container at the same path passed to
# `--mcp-config=...`.
#
# This covers both:
# - the empty-server suppression path, where Paid must pass {"mcpServers": {}}
#   explicitly to disable Claude's .mcp.json auto-discovery
# - the configured-server path, where agent-harness otherwise writes a host-side
#   tempfile during plan construction and returns a path that does not exist
#   inside the agent container
#
# Keep this patch in place until agent-harness materializes MCP config files for
# all Anthropic execution paths via ExecutionPreparation (or equivalent).
module PaidAgentHarnessAnthropicMcpConfigMaterializationPatch
  def send_message(prompt:, **options)
    super(prompt:, **with_explicit_empty_mcp_servers(options))
  end

  def plan_execution(prompt:, **options)
    super(prompt:, **with_explicit_empty_mcp_servers(options))
  end

  protected

  def build_command(prompt, options)
    command = super
    return command unless materialize_mcp_config?(options)

    mcp_flag = "--mcp-config=#{mcp_config_plan(options).fetch(:path)}"
    existing_mcp_flag = command.find { |part| part.to_s.start_with?("--mcp-config=") }
    return command[0...-1] + [ mcp_flag, command.last ] unless existing_mcp_flag

    command.map { |part| part == existing_mcp_flag ? mcp_flag : part }
  end

  def build_execution_preparation(options)
    preparation = super
    return preparation unless materialize_mcp_config?(options)

    merge_execution_preparations(
      preparation,
      AgentHarness::ExecutionPreparation.new(
        file_writes: [
          {
            path: mcp_config_plan(options).fetch(:path),
            content: mcp_config_plan(options).fetch(:content),
            mode: 0o600
          }
        ]
      )
    )
  end

  private

  def with_explicit_empty_mcp_servers(options)
    return options if options.key?(:mcp_servers)

    options.merge(mcp_servers: [])
  end

  def materialize_mcp_config?(options)
    options.key?(:mcp_servers)
  end

  def mcp_config_plan(options)
    options[:_paid_claude_mcp_config] ||= begin
      content = JSON.generate(
        AgentHarness::McpConfigTranslator.for_provider(mcp_provider_key, Array(options[:mcp_servers]))
      )

      {
        path: File.join(Dir.tmpdir, "agent_harness_claude_mcp_#{Digest::SHA256.hexdigest(content).first(16)}.json"),
        content: content
      }
    end
  end

  def merge_execution_preparations(base, extra)
    return extra if base.nil?
    return base if extra.nil?

    AgentHarness::ExecutionPreparation.new(file_writes: base.file_writes + extra.file_writes)
  end
end

AgentHarness::Providers::Anthropic.prepend(PaidAgentHarnessAnthropicMcpConfigMaterializationPatch) unless
  AgentHarness::Providers::Anthropic < PaidAgentHarnessAnthropicMcpConfigMaterializationPatch

# Force Claude's --mcp-config flag into the `--flag=value` form.
#
# The Claude CLI declares `--mcp-config <configs...>` as a *variadic* option, so
# the space-separated form ("--mcp-config", path) that agent-harness emits right
# before the positional prompt makes the CLI greedily consume the prompt as a
# second config path:
#
#   claude ... --mcp-config /tmp/cfg.json "Reply with exactly OK."
#   => Error: Invalid MCP configuration:
#      MCP config file not found: /workspace/Reply with exactly OK.
#
# The `=value` form captures exactly one path and leaves the prompt as a clean
# positional argument. This covers the with-servers path on 0.18.2 AND every
# invocation on >= 0.19.0, where the gem always passes --mcp-config (the #225
# suppression fix) but still with the buggy space-form (confirmed through v0.20.0).
#
# Intentionally NOT folded under the < 0.19.0 suppression gate above: that gate
# drops exactly when the gem starts emitting this flag everywhere, which is when
# the bug bites hardest. The guard below makes this a no-op once the gem emits a
# single equals-form token, so it self-deactivates and is safe to leave in place.
# TODO(#2435): remove once agent-harness ships the =value form (viamin/agent-harness#229).
module PaidAgentHarnessAnthropicMcpConfigFlagFormPatch
  def build_mcp_flags(mcp_servers, working_dir: nil)
    flags = super
    return flags unless flags.length == 2 && flags.first == "--mcp-config"

    [ "--mcp-config=#{flags.last}" ]
  end
end

AgentHarness::Providers::Anthropic.prepend(PaidAgentHarnessAnthropicMcpConfigFlagFormPatch) unless
  AgentHarness::Providers::Anthropic < PaidAgentHarnessAnthropicMcpConfigFlagFormPatch

# Backport embedding support until agent-harness ships a native public API.
# Keep this version-gated and narrow so Paid can switch back to upstream
# behavior cleanly once the gem exposes AgentHarness.embed (or equivalent).
# TODO(#2146): remove when agent-harness >= 0.19.0 ships native embeddings support
module PaidAgentHarnessEmbeddingTransportPatch
  PAID_TRANSPORT_ERRORS = [
    EOFError,
    OpenSSL::SSL::SSLError
  ].freeze

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
  rescue *PAID_TRANSPORT_ERRORS => e
    raise AgentHarness::ProviderError.new("HTTP connection error: #{e.message}", original_error: e)
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

unless AgentHarness.respond_to?(:embed)
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
