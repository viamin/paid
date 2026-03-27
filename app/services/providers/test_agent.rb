# frozen_string_literal: true

require "shellwords"

module Providers
  # Sends a lightweight test prompt to a provider's agent to verify
  # installation, authentication, and responsiveness.
  #
  # @example
  #   result = Providers::TestAgent.call(provider: provider)
  #   result.success? # => true
  class TestAgent
    UnsupportedProviderError = Class.new(StandardError)
    NotContainerExecutableError = Class.new(StandardError)
    MissingProjectContextError = Class.new(StandardError)

    PROMPT = "Respond with exactly: PING OK"
    EXPECTED_OUTPUT = "PING OK"
    TIMEOUT = 30
    HARNESS_HEALTH_CHECK_PROVIDER_KEYS = %w[claude].freeze
    CONTAINER_COMMANDS = Activities::RunAgentActivity::AGENT_COMMANDS.slice(
      "claude",
      "codex",
      "gemini",
      "kilocode",
      "opencode"
    ).freeze
    RATE_LIMIT_PATTERNS = Activities::RunAgentActivity::RATE_LIMIT_PATTERNS
    AUTHENTICATION_ERROR_PATTERNS = [
      /api[_ -]?key/i,
      /API key not configured for openai/i,
      /API key not configured for/i,
      /auth(?:entication)?/i,
      /oauth/i,
      /token/i,
      /unauthori[sz]ed/i,
      /invalid credentials/i,
      /session.*expired/i,
      /ValidationRequiredError/i,
      /Verify your account to continue\./i,
      /Please set an Auth method/i,
      /Missing agent run ID/i,
      /GEMINI_API_KEY/i,
      /GOOGLE_GENAI_USE_VERTEXAI/i,
      /GOOGLE_GENAI_USE_GCA/i
    ].freeze
    INSTALLATION_ERROR_PATTERNS = [
      /command not found/i,
      /No such file or directory/i,
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
    NOISY_ERROR_LINES = [
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
      /Error when talking to Gemini API/i,
      /Full report available at:/i,
      /An unexpected critical error occurred:/i,
      /service=.*\b(status|loading|subscribing|publishing|request|state|using bundled provider)\b/i,
      /\{\s*cause:/i,
      /validationLink:/i,
      /validationDescription:/i,
      /learnMoreUrl:/i,
      /userHandled:/i
    ].freeze

    attr_reader :provider

    def initialize(provider:)
      @provider = provider
    end

    def self.call(...)
      new(...).call
    end

    def call
      validate!
      return process_harness_result(execute_harness_health_check) if harness_health_check_supported?

      response = execute_container_test
      process_container_response(response)
    rescue NotContainerExecutableError
      Result.new(success: false, error_type: :installation,
        message: "Provider #{provider.provider_key} CLI is not installed in the agent container")
    rescue UnsupportedProviderError
      Result.new(success: false, error_type: :unexpected,
        message: "Provider #{provider.provider_key} is not recognized by the agent harness")
    rescue MissingProjectContextError => e
      Result.new(success: false, error_type: :unexpected, message: e.message)
    rescue Containers::Provision::TimeoutError => e
      Result.new(success: false, error_type: :timeout, message: e.message)
    rescue Containers::Provision::Error => e
      Result.new(success: false, error_type: :connection, message: e.message)
    rescue StandardError => e
      Rails.logger.error(
        message: "providers.test_agent.unexpected_error",
        provider_key: provider&.provider_key,
        error_class: e.class.name,
        error_message: e.message
      )
      Result.new(success: false, error_type: :unexpected, message: e.message)
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

    def execute_container_test
      test_run = build_test_run

      begin
        test_run.with_container do |run|
          run.execute_in_container(test_command, timeout: TIMEOUT, stream: false)
        end
      ensure
        test_run.destroy! if test_run&.persisted?
      end
    end

    def process_harness_result(result)
      status = result[:status].to_s
      message = result[:message].presence || "Provider health check returned no message"

      if status == "ok"
        Result.new(success: true, error_type: nil, message: "Agent is healthy")
      else
        Result.new(
          success: false,
          error_type: classify_failed_response(message),
          message: message
        )
      end
    end

    def process_container_response(response)
      unless response.success?
        raw_message = response[:stderr].presence || response[:stdout].presence || response.error
        message = extract_user_facing_error(raw_message)
        error_type = classify_failed_response(raw_message.presence || message)

        return Result.new(
          success: false,
          error_type: error_type,
          message: message.presence || "Agent exited with code #{response.exit_code}"
        )
      end

      output = response[:stdout].to_s.strip

      if output == EXPECTED_OUTPUT
        Result.new(success: true, error_type: nil, message: "Agent is healthy")
      else
        Result.new(
          success: false,
          error_type: :unexpected,
          message: "Agent responded but output did not match expected ping"
        )
      end
    end

    def build_test_run
      AgentRun.create!(
        project: test_project,
        agent_type: Provider.agent_type_for(provider.provider_key),
        status: "pending",
        goal: "create_pr",
        trigger_type: "manual",
        custom_prompt: PROMPT
      )
    end

    def test_project
      @test_project ||= provider.user.created_projects.active.order(:id).first ||
        provider.user.member_projects.active.order(:id).first
    end

    def harness_health_check_supported?
      HARNESS_HEALTH_CHECK_PROVIDER_KEYS.include?(provider.provider_key)
    end

    def harness_provider_name
      Provider.harness_provider_key_for(provider.provider_key).to_sym
    end

    def test_command
      command = CONTAINER_COMMANDS[provider.provider_key]
      raise UnsupportedProviderError, "Unsupported provider: #{provider.provider_key}" unless command

      # TODO(agent-harness#41): Switch Gemini and Codex to AgentHarness.check_provider
      # once provider-specific auth_status / health_status hooks exist upstream.
      return codex_test_command if provider.provider_key == "codex"
      return gemini_test_command if provider.provider_key == "gemini"
      return kilocode_test_command if provider.provider_key == "kilocode"

      command + [ PROMPT ]
    end

    def classify_failed_response(error_message)
      message = error_message.to_s

      return :rate_limited if matches_any_pattern?(message, RATE_LIMIT_PATTERNS)
      return :authentication if matches_any_pattern?(message, AUTHENTICATION_ERROR_PATTERNS)
      return :installation if matches_any_pattern?(message, INSTALLATION_ERROR_PATTERNS)
      return :timeout if matches_any_pattern?(message, TIMEOUT_ERROR_PATTERNS)
      return :connection if matches_any_pattern?(message, CONNECTION_ERROR_PATTERNS)

      :unexpected
    end

    def extract_user_facing_error(error_message)
      message = error_message.to_s.strip
      return message if message.empty?

      translated = translate_known_provider_errors(message)
      return translated if translated

      extracted = USER_FACING_ERROR_EXTRACTORS.find { |pattern| pattern.match?(message) }
      return message[extracted].strip if extracted

      cleaned_lines = message.lines
        .map(&:strip)
        .reject(&:empty?)
        .reject { |line| noisy_error_line?(line) }

      cleaned_lines.first || message.lines.first.to_s.strip
    end

    def matches_any_pattern?(message, patterns)
      patterns.any? { |pattern| pattern.match?(message) }
    end

    def noisy_error_line?(line)
      matches_any_pattern?(line, NOISY_ERROR_LINES)
    end

    def translate_known_provider_errors(message)
      return "Paid is not configured with a Google API key for containerized Gemini runs." if message.match?(/API key not configured for google/i)
      return "Paid is not configured with an OpenAI API key for containerized Codex runs." if message.match?(/API key not configured for openai/i)

      if message.match?(/Missing agent run ID/i) && message.match?(%r{/api/proxy/openai/}i)
        "Codex did not forward the Paid container credentials to the OpenAI proxy."
      end
    end

    def codex_test_command
      escaped_prompt = Shellwords.escape(PROMPT)
      <<~SH.squish
        tmp_output="$(mktemp)" &&
        tmp_error="$(mktemp)" &&
        if [ "$PAID_CODEX_SUBSCRIPTION_AUTH" = "1" ]; then
          env
          -u OPENAI_API_KEY
          -u OPENAI_BASE_URL
          -u OPENAI_HEADER_X_AGENT_RUN_ID
          -u OPENAI_HEADER_X_PROXY_TOKEN
          codex exec --full-auto --skip-git-repo-check --output-last-message "$tmp_output" -- #{escaped_prompt} >/dev/null 2>"$tmp_error";
        else
          codex exec --full-auto --skip-git-repo-check --output-last-message "$tmp_output" -- #{escaped_prompt} >/dev/null 2>"$tmp_error";
        fi;
        status=$?;
        if [ "$status" -eq 0 ]; then
          cat "$tmp_output" 2>/dev/null;
        else
          cat "$tmp_error" 2>/dev/null;
        fi;
        exit $status
      SH
    end

    def gemini_test_command
      escaped_prompt = Shellwords.escape(PROMPT)
      command = "gemini -y -p #{escaped_prompt}"
      <<~SH.squish
        if [ "$PAID_GEMINI_SUBSCRIPTION_AUTH" = "1" ]; then
          env
          -u GEMINI_API_KEY
          -u GOOGLE_GEMINI_BASE_URL
          -u GOOGLE_GENAI_BASE_URL
          -u GOOGLE_HEADER_X_AGENT_RUN_ID
          -u GOOGLE_HEADER_X_PROXY_TOKEN
          -u GEMINI_CLI_CUSTOM_HEADERS
          #{command};
        else
          #{command};
        fi
      SH
    end

    def kilocode_test_command
      escaped_prompt = Shellwords.escape(PROMPT)
      <<~SH.squish
        env
        -u OPENAI_API_KEY
        -u OPENAI_BASE_URL
        -u OPENAI_HEADER_X_AGENT_RUN_ID
        -u OPENAI_HEADER_X_PROXY_TOKEN
        -u GEMINI_API_KEY
        -u GOOGLE_GEMINI_BASE_URL
        -u GOOGLE_GENAI_BASE_URL
        -u GOOGLE_HEADER_X_AGENT_RUN_ID
        -u GOOGLE_HEADER_X_PROXY_TOKEN
        -u GEMINI_CLI_CUSTOM_HEADERS
        timeout 20s kilo run --auto --print-logs #{escaped_prompt}
      SH
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
