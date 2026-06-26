# frozen_string_literal: true

require "digest"
require Rails.root.join("lib/runner_support").to_s

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
  PI_AUTH_JSON_PATH = "/home/agent/.pi/agent/auth.json"

  # Derived lazily via a method so that Provider (an autoloaded model) is
  # guaranteed to be available regardless of initializer load order.
  def pi_api_key_env_vars = Provider::PI_API_PROVIDERS.values.map { |c| c[:env_var] }.freeze

  def api_key_env_var_names
    merge_string_lists(super, pi_api_key_env_vars)
  end

  def subscription_unset_vars
    merge_string_lists(super, pi_api_key_env_vars)
  end

  protected

  def build_execution_preparation(options)
    base = super
    runtime = options[:provider_runtime]
    auth_entry = runtime&.metadata&.dig("paid_pi_auth_entry")
    return base unless auth_entry.is_a?(Hash)
    return base if preparation_writes_pi_auth_json?(base)

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
          path: PI_AUTH_JSON_PATH,
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

  def merge_string_lists(*lists)
    lists
      .compact
      .flat_map { |list| Array(list) }
      .uniq
      .freeze
  end

  def preparation_writes_pi_auth_json?(preparation)
    Array(preparation&.file_writes).any? { |write| write.path == PI_AUTH_JSON_PATH }
  end
end

# Keep this patch loaded until agent-harness ships native Pi API-key auth.
# This no longer uses a speculative version ceiling: 0.20.0 proved that turning
# the patch off on an assumed release boundary can silently break every Pi
# API-key runner. The overrides self-deactivate instead:
# - env-var helpers union with upstream values once the gem adds them
# - auth.json materialization skips itself when upstream already prepares that
#   file for the request
# TODO(#2077): remove once native Pi API-key support is confirmed upstream.
AgentHarness::Providers::Pi.prepend(PaidAgentHarnessPiRuntimePatch) unless
  AgentHarness::Providers::Pi < PaidAgentHarnessPiRuntimePatch

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

# Backport PKCE code-exchange API for Claude OAuth (Phase 4c of RDR-041).
#
# agent-harness 0.23.0 exposes `auth_url` (static authorize URL) and
# `refresh_auth` (stores a pre-exchanged token), but has no code-exchange
# flow. This patch adds three class methods to Authentication:
#
# - `generate_pkce_challenge` → { code_verifier:, code_challenge: }
# - `auth_url_with_pkce(provider)` → { url:, code_verifier: }
# - `exchange_code(provider, code:, code_verifier:)` → token hash
#
# Only needed as a last resort (Phase 4c) when the official CLI login
# (4a) and upstream `--code` flag (4b) are both infeasible.
# TODO(#2682): remove once agent-harness ships a native code-exchange API.
module PaidAgentHarnessClaudePkceCodeExchangePatch
  CLAUDE_TOKEN_ENDPOINT = "https://claude.ai/oauth/token"
  PKCE_VERIFIER_LENGTH = 43 # RFC 7636 §4.1 requires 43–128 chars; urlsafe_base64(43) → ~58 URL-safe chars
  PKCE_CHALLENGE_METHOD = "S256"
  HTTP_TIMEOUT_SECONDS = 30

  # Generate a PKCE challenge pair (code_verifier + code_challenge).
  #
  # @return [Hash] with :code_verifier (String) and :code_challenge (String)
  def generate_pkce_challenge
    code_verifier = SecureRandom.urlsafe_base64(PKCE_VERIFIER_LENGTH)
    code_challenge = Base64.urlsafe_encode64(
      Digest::SHA256.digest(code_verifier),
      padding: false
    )
    { code_verifier: code_verifier, code_challenge: code_challenge }
  end

  # Generate an OAuth authorize URL with PKCE parameters for a provider.
  #
  # Returns both the URL (which the user must visit) and the code_verifier
  # (which the caller must store and pass to `exchange_code` later).
  #
  # @param provider_name [Symbol] the provider name (only :claude / :anthropic supported)
  # @param redirect_uri [String] OAuth redirect URI (default: urn:ietf:wg:oauth:2.0:oob for manual paste)
  # @param scope [String] OAuth scope (default: user:inference)
  # @return [Hash] with :url (String), :code_verifier (String), :code_challenge (String), :state (String)
  # @raise [UnsupportedAuthFlowError] if provider doesn't support OAuth
  def auth_url_with_pkce(provider_name, redirect_uri: "urn:ietf:wg:oauth:2.0:oob", scope: "user:inference")
    provider_name = provider_name.to_sym
    base_url = auth_url(provider_name)
    pkce = generate_pkce_challenge
    state = SecureRandom.urlsafe_base64(24)

    params = URI.encode_www_form(
      response_type: "code",
      code_challenge: pkce[:code_challenge],
      code_challenge_method: PKCE_CHALLENGE_METHOD,
      redirect_uri: redirect_uri,
      scope: scope,
      state: state
    )

    {
      url: "#{base_url}?#{params}",
      code_verifier: pkce[:code_verifier],
      code_challenge: pkce[:code_challenge],
      state: state
    }
  end

  # Exchange an OAuth authorization code + PKCE verifier for tokens.
  #
  # @param provider_name [Symbol] the provider name (only :claude / :anthropic supported)
  # @param code [String] the authorization code from the OAuth callback
  # @param code_verifier [String] the PKCE verifier generated by `auth_url_with_pkce`
  # @param redirect_uri [String] must match the redirect_uri used in the authorize request
  # @return [Hash] parsed token response with string keys (access_token, refresh_token, expires_in, etc.)
  # @raise [UnsupportedAuthFlowError] if provider doesn't support OAuth code exchange
  # @raise [AuthenticationError] if the token exchange fails
  def exchange_code(provider_name, code:, code_verifier:, redirect_uri: "urn:ietf:wg:oauth:2.0:oob")
    provider_name = provider_name.to_sym
    validate_exchange_code_provider!(provider_name)
    validate_exchange_code_params!(code, code_verifier)

    token_endpoint = claude_token_endpoint
    body = {
      grant_type: "authorization_code",
      code: code.strip,
      code_verifier: code_verifier,
      redirect_uri: redirect_uri
    }

    response = post_token_request(token_endpoint, body)
    parse_token_response(response, provider_name)
  end

  private

  def validate_exchange_code_provider!(provider_name)
    unless [ :claude, :anthropic ].include?(provider_name)
      raise AgentHarness::UnsupportedAuthFlowError,
        "PKCE code exchange is not implemented for provider #{provider_name}"
    end
  end

  def validate_exchange_code_params!(code, code_verifier)
    raise ArgumentError, "code must be a non-empty string" unless code.is_a?(String) && !code.strip.empty?
    raise ArgumentError, "code_verifier must be a non-empty string" unless code_verifier.is_a?(String) && !code_verifier.strip.empty?
  end

  def claude_token_endpoint
    CLAUDE_TOKEN_ENDPOINT
  end

  def post_token_request(endpoint, body)
    uri = URI(endpoint)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = HTTP_TIMEOUT_SECONDS
    http.read_timeout = HTTP_TIMEOUT_SECONDS

    request = Net::HTTP::Post.new(uri.path)
    request["Content-Type"] = "application/x-www-form-urlencoded"
    request["Accept"] = "application/json"
    request.body = URI.encode_www_form(body)

    http.request(request)
  rescue Errno::ECONNREFUSED, Errno::ETIMEDOUT, Net::OpenTimeout,
         Net::ReadTimeout, SocketError, OpenSSL::SSL::SSLError => e
    raise AgentHarness::AuthenticationError.new(
      "Failed to connect to token endpoint: #{e.message}",
      provider: :claude,
      original_error: e
    )
  end

  def parse_token_response(response, provider_name)
    status = response.code.to_i
    body = JSON.parse(response.body)

    if status == 200
      body
    else
      error_description = body["error_description"] || body["error"] || "Unknown error"
      raise AgentHarness::AuthenticationError.new(
        "OAuth code exchange failed (HTTP #{status}): #{error_description}",
        provider: provider_name,
        context: { status: status, error: body["error"], error_description: body["error_description"] }
      )
    end
  rescue JSON::ParserError => e
    raise AgentHarness::AuthenticationError.new(
      "Invalid JSON in token response (HTTP #{response.code})",
      provider: provider_name,
      original_error: e
    )
  end
end

AgentHarness::Authentication.singleton_class.prepend(PaidAgentHarnessClaudePkceCodeExchangePatch) unless
  AgentHarness::Authentication.singleton_class < PaidAgentHarnessClaudePkceCodeExchangePatch

# Default agent timeout used for AgentHarness boot-time config and as a
# fallback when per-user settings are unavailable. Runtime code should
# prefer UserSetting#agent_timeout_seconds resolved via
# AgentRuns::UserSettingsResolver.
AGENT_TIMEOUT_DEFAULT = 5400
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
