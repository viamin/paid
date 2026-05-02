# frozen_string_literal: true

module Providers
  # Sends a lightweight test prompt to a provider's agent to verify
  # installation, authentication, and responsiveness.
  #
  # Delegates smoke-test execution to agent-harness via two paths:
  # 1. Harness health check — lightweight API-level check when a Paid-managed
  #    API key is configured (e.g. Codex/Gemini with proxy keys).
  # 2. Container smoke test — runs the harness smoke_test contract inside a
  #    provisioned Docker container via Containers::HarnessExecutor.
  #
  # @example
  #   result = Providers::TestAgent.call(provider: provider)
  #   result.success? # => true
  class TestAgent
    UnsupportedProviderError = Class.new(StandardError)
    NotContainerExecutableError = Class.new(StandardError)
    MissingProjectContextError = Class.new(StandardError)

    TIMEOUT = 60
    RATE_LIMIT_PATTERNS = Activities::RunAgentActivity::RATE_LIMIT_PATTERNS
    # Base authentication patterns shared across all providers. Provider-specific
    # patterns are sourced from agent-harness error_classification_patterns[:authentication].
    BASE_AUTHENTICATION_ERROR_PATTERNS = [
      /api[_ -]?key/i,
      /API key not configured for/i,
      /auth(?:entication)?/i,
      /oauth/i,
      /token/i,
      /unauthori[sz]ed/i,
      /invalid credentials/i,
      /session.*expired/i
    ].freeze
    INSTALLATION_ERROR_PATTERNS = [
      /command not found/i,
      /No such file or directory/i,
      /executable file not found in \$PATH/i,
      /not installed/i
    ].freeze
    TIMEOUT_ERROR_PATTERNS = [
      /timed out/i,
      /timeout/i
    ].freeze
    CONNECTION_ERROR_PATTERNS = [
      /connection refused/i,
      /connection reset/i,
      /could not connect/i,
      /network/i,
      /ENOTFOUND/i,
      /ECONN/i
    ].freeze
    USER_FACING_ERROR_EXTRACTORS = [
      /Free model usage limit reached\..*?(?="|\n|$)/i,
      /\[API Error: \{"error":"API key not configured for google"\}\]/i,
      /\[API Error: \{"error":"API key not configured for openai"\}\]/i,
      /Free model usage limit reached.*?(?=\n|$)/i,
      /Rate limit exceeded.*?(?=\n|$)/i,
      /API key not configured for openai.*?(?=\n|$)/i,
      /Verify your account to continue\./i,
      /Please set an Auth method.*?(?=\n|$)/i,
      /Invalid API key.*?(?=\n|$)/i,
      /API key not configured for google.*?(?=\n|$)/i,
      /Missing agent run ID.*?(?=\n|$)/i,
      /Authentication failed.*?(?=\n|$)/i,
      /Unauthorized.*?(?=\n|$)/i,
      /Timed out.*?(?=\n|$)/i,
      /Connection refused.*?(?=\n|$)/i
    ].freeze
    ANSI_ESCAPE_PATTERN = /\e\[[0-9;?]*[ -\/]*[@-~]/
    # Base noisy-error patterns shared across all providers. Provider-specific
    # patterns are sourced from agent-harness noisy_error_patterns.
    BASE_NOISY_ERROR_LINES = [
      /^INFO\s+\d{4}-\d{2}-\d{2}T/i,
      /^OpenAI Codex v/i,
      /^-+$/,
      /^workdir:/i,
      /^model:/i,
      /^provider:/i,
      /^approval:/i,
      /^sandbox:/i,
      /^reasoning /i,
      /^session id:/i,
      /^user$/i,
      /^mcp startup:/i,
      /^Reconnecting\.\.\./i,
      /punycode.*deprecated/i,
      /Use `node --trace-deprecation/i,
      /Keychain initialization encountered an error/i,
      /Using FileKeychain fallback/i,
      /Loaded cached credentials/i,
      /Validation handler failed:/i,
      %r{^\s*at\s+},
      /Full report available at:/i,
      /An unexpected critical error occurred:/i,
      /service=.*\b(status|loading|subscribing|publishing|request|state|using bundled provider)\b/i,
      /\{\s*cause:/i,
      /validationLink:/i,
      /validationDescription:/i,
      /learnMoreUrl:/i,
      /userHandled:/i
    ].freeze

    # Maps agent-harness error_category symbols to app-level error_type symbols.
    HARNESS_ERROR_CATEGORY_MAP = {
      rate_limit: :rate_limited,
      rate_limited: :rate_limited,
      quota: :rate_limited,
      quota_exceeded: :rate_limited,
      authentication: :authentication,
      auth_expired: :authentication,
      installation: :installation,
      timeout: :timeout,
      transient: :connection,
      configuration: :unexpected,
      unknown: :unexpected
    }.freeze

    attr_reader :provider

    def initialize(provider:)
      @provider = provider
    end

    def self.call(...)
      new(...).call
    end

    def call
      validate!
      result = if harness_health_check_supported?
        process_harness_result(execute_harness_health_check)
      else
        execute_container_smoke_test
      end

      update_provider_state!(result)
      result
    rescue NotContainerExecutableError
      Result.new(success: false, error_type: :installation,
        message: "Provider #{provider.provider_key} CLI is not installed in the agent container")
    rescue UnsupportedProviderError
      Result.new(success: false, error_type: :unexpected,
        message: "Provider #{provider.provider_key} is not recognized by the agent harness")
    rescue MissingProjectContextError => e
      Result.new(success: false, error_type: :unexpected, message: normalize_output_text(e.message))
    rescue Containers::Provision::TimeoutError => e
      Result.new(success: false, error_type: :timeout, message: normalize_output_text(e.message))
    rescue Containers::Provision::Error => e
      Result.new(success: false, error_type: :connection, message: normalize_output_text(e.message))
    rescue StandardError => e
      Rails.logger.error(
        message: "providers.test_agent.unexpected_error",
        provider_key: provider&.provider_key,
        error_class: e.class.name,
        error_message: normalize_output_text(e.message)
      )
      Result.new(success: false, error_type: :unexpected, message: normalize_output_text(e.message))
    end

    private

    def validate!
      unless ProviderSupport.supported_provider_key?(provider.provider_key)
        raise UnsupportedProviderError, "Unknown provider: #{provider.provider_key}"
      end

      unless ProviderSupport.container_executable_provider_key?(provider.provider_key)
        raise NotContainerExecutableError,
          "Provider #{provider.provider_key} is not installed in the agent container"
      end

      return if harness_health_check_supported?

      raise MissingProjectContextError, "Add a project before testing providers in the agent container" unless test_project
    end

    def execute_harness_health_check
      AgentHarness.check_provider(harness_provider_name, timeout: TIMEOUT)
    end

    # Runs the agent-harness smoke_test contract inside a provisioned container.
    #
    # Instead of building provider-specific CLI commands locally, this delegates
    # to the harness provider's smoke_test method with a container-backed executor.
    def execute_container_smoke_test
      test_run = build_test_run

      begin
        test_run.with_container do |run|
          executor = Containers::HarnessExecutor.new(run)
          prepare_kilocode_config!(run) if kilocode_direct_outbound?
          harness_result = AgentHarness.check_provider(
            harness_provider_name,
            timeout: TIMEOUT,
            executor: executor,
            provider_runtime: container_provider_runtime
          )
          process_harness_result(harness_result)
        end
      ensure
        test_run.destroy! if test_run&.persisted?
      end
    end

    def process_harness_result(result)
      status = result[:status].to_s
      message = normalize_output_text(result[:message]).presence || "Provider health check returned no message"

      if status == "ok"
        Result.new(success: true, error_type: nil, message: "Agent is healthy")
      else
        error_type = map_harness_error_category(result[:error_category]) ||
          classify_failed_response(message)
        translated_message = translate_and_extract_error(message)

        Result.new(
          success: false,
          error_type: error_type,
          message: translated_message.presence || message
        )
      end
    end

    def map_harness_error_category(category)
      return nil unless category

      HARNESS_ERROR_CATEGORY_MAP[category.to_sym]
    end

    # Builds a ProviderRuntime for container-based smoke tests.
    #
    # For direct-outbound providers (e.g. opencode with API key), this returns
    # the provider's full runtime with env/base_url overrides. For kilocode
    # direct-outbound, this builds a runtime with the upstream API key env
    # (config file bootstrap is handled by prepare_kilocode_config!).
    # For standard subscription-auth providers, this returns nil (the provider
    # runs through the Paid proxy with inherited container env).
    def container_provider_runtime
      return kilocode_provider_runtime if kilocode_direct_outbound?

      provider.agent_harness_provider_runtime
    end

    # Builds a ProviderRuntime for kilocode direct-outbound smoke tests.
    #
    # Kilocode reads its model/provider config from ~/.config/kilo/config.json
    # (materialized by prepare_kilocode_config!) and picks up the upstream API
    # key from environment variables. This runtime passes the API key through
    # the correct env var for the configured upstream provider.
    def kilocode_provider_runtime
      api_key = provider.provider_api_key&.api_key.to_s
      api_provider = provider.kilocode_api_provider
      api_config = Provider::DIRECT_OUTBOUND_API_PROVIDERS.fetch(
        api_provider, Provider::DIRECT_OUTBOUND_API_PROVIDERS["anthropic"]
      )

      env_var = if api_config[:kilocode_api] && api_config[:kilocode_api] != "openai-compatible"
        "#{api_provider.upcase}_API_KEY"
      else
        "OPENAI_API_KEY"
      end

      env = { env_var => api_key }
      base_url = api_config[:base_url]
      if base_url && !api_config[:kilocode_api]
        default_openai_url = Provider::DIRECT_OUTBOUND_API_PROVIDERS.dig("openai", :base_url)
        env["OPENAI_BASE_URL"] = base_url if base_url != default_openai_url
      end

      AgentHarness::ProviderRuntime.new(
        model: provider.kilocode_model_id,
        api_provider: api_provider,
        env: env
      )
    end

    def kilocode_direct_outbound?
      provider.provider_key == "kilocode" && provider.requires_direct_outbound?
    end

    # Writes the kilocode config file into the container before the smoke test.
    #
    # Uses a direct container exec instead of ExecutionPreparation because
    # ExecutionPreparation cleans up files after each execute call (see
    # provision.rb ensure block), which removes the config before the
    # subsequent smoke test runs.
    def prepare_kilocode_config!(run)
      config_json = provider.kilocode_config_json
      run.execute_in_container(
        [ "sh", "-c",
          "mkdir -p /home/agent/.config/kilo && " \
          "printf '%s' \"$KILOCODE_CONFIG_B64\" | base64 -d > /home/agent/.config/kilo/config.json" ],
        timeout: 30,
        env: { "KILOCODE_CONFIG_B64" => Base64.strict_encode64(config_json) }
      )
    end

    def build_test_run
      # Use insert_all! to bypass after_commit callbacks (broadcasts, project
      # timestamp updates, capacity accounting) for this ephemeral test record.
      # The row is destroyed as soon as the container test completes.
      now = Time.current
      result = AgentRun.insert_all!(
        [ {
          project_id: test_project.id,
          provider_id: provider.id,
          agent_type: Provider.agent_type_for(provider.provider_key),
          status: "queued",
          goal: "create_pr",
          trigger_type: "manual",
          custom_prompt: "smoke_test",
          proxy_token: SecureRandom.hex(32),
          created_at: now,
          updated_at: now
        } ],
        returning: [ :id ]
      )
      AgentRun.find(result.first["id"])
    end

    def test_project
      @test_project ||= provider.user.created_projects.active.order(:id).first ||
        provider.user.member_projects.active.order(:id).first
    end

    def harness_health_check_supported?
      api_key_name = ProviderSupport.proxy_health_check_api_key_for(provider.provider_key)
      !!(api_key_name && proxy_api_key_configured?(api_key_name))
    end

    def harness_provider_name
      ProviderSupport.harness_provider_key_for(provider.provider_key).to_sym
    end

    def proxy_api_key_configured?(provider_name)
      Rails.application.credentials.dig(:llm, :"#{provider_name}_api_key").present? ||
        ENV["#{provider_name.to_s.upcase}_API_KEY"].present?
    end

    def update_provider_state!(result)
      if result.success?
        clear_provider_state_if_healthy!
      elsif result.error_type == :rate_limited
        persist_rate_limited_state!(result.message)
      end
    end

    def clear_provider_state_if_healthy!
      provider_state_names.each do |provider_name|
        provider.user.provider_states.find_by(provider_name: provider_name)&.record_success!
      end
    end

    def persist_rate_limited_state!(message)
      reset_at = rate_limit_reset_at(message)

      provider_state_names.each do |provider_name|
        provider.user.provider_states.find_or_create_by!(provider_name: provider_name).mark_rate_limited!(reset_at: reset_at)
      end
    rescue ActiveRecord::RecordNotUnique
      provider_state_names.each do |provider_name|
        provider.user.provider_states.find_by!(provider_name: provider_name).mark_rate_limited!(reset_at: reset_at)
      end
    end

    def provider_state_names
      names = [ provider.state_key ]
      if provider.subscription? || provider.state_key == provider.provider_key
        names << provider.provider_key
      end

      names.uniq
    end

    def rate_limit_reset_at(message)
      agent_harness_provider = harness_provider
      parsed_reset = agent_harness_provider.parse_rate_limit_reset(message.to_s) ||
        agent_harness_provider.parse_rate_limit_reset(normalized_rate_limit_reset_text(message)) ||
        1.hour.from_now
      parsed_reset > Time.current ? parsed_reset : 1.hour.from_now
    rescue AgentHarness::ConfigurationError, KeyError
      1.hour.from_now
    end

    def harness_provider
      AgentHarness.provider(harness_provider_name)
    end

    def normalized_rate_limit_reset_text(message)
      message.to_s
        .gsub(/retry.?after:?\s*(\d+)(?!\s*s)/i, 'retry after \1s')
        .gsub(/reset.?at:?\s*(\d+)/i, 'reset at \1')
    end

    def classify_failed_response(error_message)
      message = error_message.to_s

      return :rate_limited if matches_any_pattern?(message, RATE_LIMIT_PATTERNS)
      return :authentication if matches_any_pattern?(message, authentication_error_patterns)
      return :installation if matches_any_pattern?(message, INSTALLATION_ERROR_PATTERNS)
      return :timeout if matches_any_pattern?(message, TIMEOUT_ERROR_PATTERNS)
      return :connection if matches_any_pattern?(message, CONNECTION_ERROR_PATTERNS)

      :unexpected
    end

    def translate_and_extract_error(error_message)
      translated = translate_known_provider_errors(error_message)
      return translated if translated

      extract_user_facing_error(error_message)
    end

    def extract_user_facing_error(error_message)
      message = sanitize_error_message(error_message)
      return message if message.empty?

      translated = ProviderSupport.translate_provider_error(provider.provider_key, message)
      return translated if translated

      extracted = USER_FACING_ERROR_EXTRACTORS.find { |pattern| pattern.match?(message) }
      return message[extracted].strip if extracted

      cleaned_lines = message.lines
        .map(&:strip)
        .reject(&:empty?)
        .reject { |line| line.match?(/\A[^\p{Alnum}]+\z/) }
        .reject { |line| noisy_error_line?(line) }

      cleaned_lines.first || message.lines.first.to_s.strip
    end

    def matches_any_pattern?(message, patterns)
      message = sanitize_error_message(message)
      patterns.any? { |pattern| pattern.match?(message) }
    end

    def noisy_error_line?(line)
      matches_any_pattern?(line, noisy_error_line_patterns)
    end

    def sanitize_error_message(error_message)
      normalize_output_text(error_message)
        .dup
        .gsub(ANSI_ESCAPE_PATTERN, "")
        .delete("\u0000")
        .strip
    end

    include OutputSanitizer

    def translate_known_provider_errors(message)
      # Paid-specific translations that reference container/proxy infrastructure
      # take priority since they provide more actionable context than generic
      # agent-harness translations.
      translate_paid_specific_errors(message)
    end

    def translate_paid_specific_errors(message)
      if message.match?(/API key not configured for google/i)
        return "Paid is not configured with a Google API key for containerized Gemini runs."
      end

      if message.match?(/API key not configured for openai/i)
        return "Paid is not configured with an OpenAI API key for containerized OpenAI-backed runs (Codex or OpenCode)."
      end

      if message.match?(/exec:\s*"github-copilot-cli": executable file not found in \$PATH/i)
        return "GitHub Copilot CLI is missing from the agent container. Rebuild the paid-agent image to install the fixed Copilot CLI package."
      end

      if message.match?(/Missing agent run ID/i) && message.match?(%r{/api/proxy/openai/}i)
        return "Codex did not forward the Paid container credentials to the OpenAI proxy."
      end

      nil
    end

    def authentication_error_patterns
      @authentication_error_patterns ||= BASE_AUTHENTICATION_ERROR_PATTERNS +
        ProviderSupport.error_classification_patterns_for(provider.provider_key, :authentication)
    end

    def noisy_error_line_patterns
      @noisy_error_line_patterns ||= BASE_NOISY_ERROR_LINES +
        ProviderSupport.aggregated_noisy_error_patterns
    end

    class Result
      attr_reader :error_type, :message

      def initialize(success:, error_type: nil, message: nil)
        @success = success
        @error_type = error_type
        @message = message
      end

      def success?
        @success
      end
    end
  end
end
