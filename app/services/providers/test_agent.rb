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
    TIMEOUT = 60
    CONTAINER_COMMANDS = Activities::RunAgentActivity::AGENT_COMMANDS.slice(
      "claude",
      "codex",
      "cursor",
      "gemini",
      "kilocode",
      "opencode",
      "copilot"
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
      result = if harness_health_check_supported?
        process_harness_result(execute_harness_health_check)
      else
        response = execute_container_test
        process_container_response(response)
      end

      clear_provider_state_if_healthy! if result.success?
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

    def execute_container_test
      test_run = build_test_run
      context = container_test_context

      begin
        test_run.with_container do |run|
          run.execute_in_container(context.fetch(:command), timeout: TIMEOUT, stream: false, env: context.fetch(:env))
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
        stderr = normalize_output_text(response[:stderr])
        stdout = normalize_output_text(response[:stdout])
        raw_message = stderr.presence || stdout.presence || normalize_output_text(response.error)
        message = extract_user_facing_error(raw_message)
        error_type = classify_failed_response(raw_message.presence || message)

        return Result.new(
          success: false,
          error_type: error_type,
          message: message.presence || "Agent exited with code #{response.exit_code}"
        )
      end

      output = normalize_output_text(response[:stdout]).strip

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
      # Use insert_all! to bypass after_commit callbacks (broadcasts, project
      # timestamp updates, capacity accounting) for this ephemeral test record.
      # The row is destroyed as soon as the container test completes.
      now = Time.current
      result = AgentRun.insert_all!(
        [ {
          project_id: test_project.id,
          provider_id: provider.id,
          agent_type: Provider.agent_type_for(provider.provider_key),
          status: "pending",
          goal: "create_pr",
          trigger_type: "manual",
          custom_prompt: PROMPT,
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

    def clear_provider_state_if_healthy!
      provider_names = [ provider.state_key ]
      if provider.subscription? || provider.state_key == provider.provider_key
        provider_names << provider.provider_key
      end

      provider_names.uniq.each do |provider_name|
        provider.user.provider_states.find_by(provider_name: provider_name)&.record_success!
      end
    end

    def container_test_context
      {
        command: test_command,
        env: test_command_env
      }
    end

    def test_command
      command = CONTAINER_COMMANDS[provider.provider_key]
      raise UnsupportedProviderError, "Unsupported provider: #{provider.provider_key}" unless command

      # This method only builds the container-exec command after that path has
      # already been selected elsewhere. For Copilot on this path, preserve the
      # installed CLI contract (`github-copilot-cli --message ...`) rather
      # than applying any harness-specific invocation shape.
      return codex_test_command if provider.provider_key == "codex"
      return gemini_test_command if provider.provider_key == "gemini"
      return provider.direct_outbound_exec_command(command_prefix: command, prompt: PROMPT) if provider.requires_direct_outbound?
      return kilocode_test_command if provider.provider_key == "kilocode"

      command + [ PROMPT ]
    end

    def test_command_env
      provider.direct_outbound_exec_env
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
      message = sanitize_error_message(error_message)
      return message if message.empty?

      translated = translate_known_provider_errors(message)
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
      matches_any_pattern?(line, NOISY_ERROR_LINES)
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
      return "Paid is not configured with a Google API key for containerized Gemini runs." if message.match?(/API key not configured for google/i)
      if message.match?(/API key not configured for openai/i)
        return "Paid is not configured with an OpenAI API key for containerized OpenAI-backed runs (Codex or OpenCode)."
      end

      if message.match?(/exec:\s*"github-copilot-cli": executable file not found in \$PATH/i)
        return "GitHub Copilot CLI is missing from the agent container. Rebuild the paid-agent image to install the fixed Copilot CLI package."
      end

      if message.match?(/Missing agent run ID/i) && message.match?(%r{/api/proxy/openai/}i)
        "Codex did not forward the Paid container credentials to the OpenAI proxy."
      end
    end

    def codex_test_command
      escaped_prompt = Shellwords.escape(PROMPT)
      command = command_with_flags_before_separator(
        CONTAINER_COMMANDS.fetch("codex"),
        "--skip-git-repo-check",
        "--output-last-message",
        "$tmp_output"
      ).join(" ")
      unset_flags = subscription_auth_unset_flags("codex")
      <<~SH.squish
        tmp_output="$(mktemp)" &&
        tmp_error="$(mktemp)" &&
        if [ "$PAID_CODEX_SUBSCRIPTION_AUTH" = "1" ]; then
          env #{unset_flags} #{command} #{escaped_prompt} >/dev/null 2>"$tmp_error";
        else
          #{command} #{escaped_prompt} >/dev/null 2>"$tmp_error";
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

    def command_with_flags_before_separator(command, *flags)
      separator_index = command.index("--") || command.length
      command[0...separator_index] + flags + command[separator_index..]
    end

    def gemini_test_command
      escaped_prompt = Shellwords.escape(PROMPT)
      command = "gemini -y -p #{escaped_prompt}"
      unset_flags = subscription_auth_unset_flags("gemini")
      <<~SH.squish
        tmp_output="$(mktemp)" &&
        tmp_error="$(mktemp)" &&
        before_report="$(ls -t /tmp/gemini-client-error-*.json 2>/dev/null | head -n 1 || true)" &&
        if [ "$PAID_GEMINI_SUBSCRIPTION_AUTH" = "1" ]; then
          env #{unset_flags} #{command} >"$tmp_output" 2>"$tmp_error";
        else
          #{command} >"$tmp_output" 2>"$tmp_error";
        fi;
        status=$?;
        after_report="$(ls -t /tmp/gemini-client-error-*.json 2>/dev/null | head -n 1 || true)";
        if [ "$status" -eq 0 ] && grep -q "Error when talking to Gemini API" "$tmp_error"; then
          if [ -n "$after_report" ] && [ "$after_report" != "$before_report" ]; then
            ruby -rjson -e 'path = ARGV[0]; data = JSON.parse(File.read(path)); puts(data.dig("error", "message") || File.read(path))' "$after_report" || cat "$tmp_error" 2>/dev/null;
          else
            cat "$tmp_error" 2>/dev/null;
          fi;
          exit 1;
        fi;
        if [ "$status" -eq 0 ]; then
          cat "$tmp_output" 2>/dev/null;
        else
          cat "$tmp_error" 2>/dev/null;
        fi;
        exit $status
      SH
    end

    def kilocode_test_command
      escaped_prompt = Shellwords.escape(PROMPT)
      all_unset_flags = all_subscription_auth_unset_vars
        .values
        .flatten
        .uniq
        .map { |var| "-u #{var}" }
        .join(" ")
      <<~SH.squish
        env #{all_unset_flags}
        timeout 20s kilo run --auto --print-logs #{escaped_prompt}
      SH
    end

    def subscription_auth_unset_flags(provider)
      subscription_auth_unset_vars_for(provider)
        .map { |var| "-u #{var}" }
        .join(" ")
    end

    def subscription_auth_unset_vars_for(provider)
      ProviderSupport.subscription_auth_unset_vars_for(provider)
    end

    def all_subscription_auth_unset_vars
      ProviderSupport.subscription_auth_unset_vars
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
