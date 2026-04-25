# frozen_string_literal: true

require "shellwords"
require "tempfile"

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

    def execute_container_test
      test_run = build_test_run
      context = container_test_context

      begin
        test_run.with_container do |run|
          exec_options = {
            timeout: TIMEOUT,
            stream: false,
            env: context.fetch(:env)
          }
          exec_options[:preparation] = context[:preparation] if context[:preparation]

          run.execute_in_container(context.fetch(:command), **exec_options)
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
        parsed_error = parse_provider_test_error(raw_message)
        provider_message = parsed_error&.fetch(:message, nil).presence || raw_message
        message = extract_user_facing_error(provider_message)
        error_type = classify_failed_response(provider_message.presence || message)

        return Result.new(
          success: false,
          error_type: error_type,
          message: message.presence || "Agent exited with code #{response.exit_code}"
        )
      end

      output = extract_ping_output(response[:stdout])

      if output.include?(EXPECTED_OUTPUT)
        Result.new(success: true, error_type: nil, message: "Agent is healthy")
      else
        Result.new(
          success: false,
          error_type: :unexpected,
          message: "Agent responded but output did not match expected ping"
        )
      end
    end

    # Extracts the agent text response from stdout, handling multiple output
    # formats that providers produce:
    #
    # - Plain text ("PING OK") — direct match
    # - JSON envelope (Claude --output-format=json) — extracts "result" field
    # - JSONL (Kilocode --format json) — extracts "text" from structured events
    # - Noisy output (OpenCode migration, tool banners) — strips known noise
    def extract_ping_output(stdout)
      raw = normalize_output_text(stdout).strip
      return raw if raw == EXPECTED_OUTPUT

      extract_from_json_envelope(raw) ||
        extract_from_jsonl(raw) ||
        strip_noise_from_output(raw)
    end

    def extract_from_json_envelope(raw)
      parsed = JSON.parse(raw)
      return nil unless parsed.is_a?(Hash)

      result = parsed["result"]
      result.is_a?(String) ? result.strip : nil
    rescue JSON::ParserError
      nil
    end

    def extract_from_jsonl(raw)
      text_parts = []
      raw.each_line do |line|
        line = line.strip
        next if line.empty?

        begin
          event = JSON.parse(line)
          next unless event.is_a?(Hash)

          text = extract_text_from_jsonl_event(event)
          text_parts << text if text
        rescue JSON::ParserError
          text_parts << line
        end
      end

      text_parts.any? ? text_parts.join.strip : nil
    end

    def extract_text_from_jsonl_event(event)
      case event["type"]
      when "text"
        event.dig("part", "text") || event["text"]
      when "result"
        event["result"] || event.dig("part", "text") || event["text"] || event["message"]
      end
    end

    OUTPUT_NOISE_PATTERNS = [
      /Performing one time database migration/i,
      /npm warn/i
    ].freeze

    def strip_noise_from_output(raw)
      cleaned = raw.lines
        .map(&:strip)
        .reject(&:empty?)
        .reject { |line| OUTPUT_NOISE_PATTERNS.any? { |p| p.match?(line) } }
        .join(" ")
        .strip

      cleaned.presence || raw
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

    def container_test_context
      {
        command: test_command,
        env: test_command_env,
        preparation: test_command_preparation
      }
    end

    def test_command
      unless ProviderSupport.container_executable_provider_key?(provider.provider_key)
        raise UnsupportedProviderError, "Unsupported provider: #{provider.provider_key}"
      end

      return harness_runtime_command if provider.agent_harness_runtime?

      plan = harness_test_plan
      if provider.requires_direct_outbound?
        provider.direct_outbound_exec_command(command_prefix: plan.command[0..-2], prompt: PROMPT)
      else
        container_test_command
      end
    end

    def test_command_env
      return direct_outbound_execution_plan.env if provider.agent_harness_runtime?

      provider.direct_outbound_exec_env
    end

    def test_command_preparation
      return nil unless provider.agent_harness_runtime?

      direct_outbound_execution_plan.preparation
    end

    def direct_outbound_execution_plan
      @direct_outbound_execution_plan ||= Providers::HarnessExecutionPlan.call(
        provider: provider,
        prompt: PROMPT
      )
    end

    def harness_test_plan
      @harness_test_plan ||= Providers::HarnessExecutionPlan.for_provider_key(
        provider_key: provider.provider_key,
        prompt: PROMPT,
        options: { dangerous_mode: true }
      )
    end

    # Wraps the harness execution plan command with `env -u` to strip
    # proxy-specific headers inherited from container startup.
    def harness_runtime_command
      plan = direct_outbound_execution_plan
      unset_vars = ProviderSupport.harness_runtime_unset_vars_for(provider.provider_key)
      ProviderSupport.command_with_unset_env(plan.command, unset_vars)
    end

    def container_test_command
      return kilocode_test_command_wrapper if kilocode_test_command?
      return shell_wrapped_test_command if shell_wrapped_test_command?

      test_command_prefix + [ PROMPT ]
    end

    def test_command_prefix(output_file: nil)
      base_command = harness_test_plan.command[0..-2]
      overrides = provider_test_command_overrides.dup

      if output_file
        output_flag_index = overrides.index("--output-last-message")
        overrides.insert(output_flag_index + 1, output_file) if output_flag_index
      end

      separator_index = base_command.index("--") || base_command.length
      base_command[0...separator_index] + overrides + base_command[separator_index..]
    end

    def shell_wrapped_test_command?
      codex_test_output_capture? || gemini_test_error_capture?
    end

    def shell_wrapped_test_command
      command_prefix = shell_join_command(test_command_prefix(output_file: "$tmp_output"))
      unset_vars = provider_test_unset_vars
      env_flag = "PAID_#{provider.provider_key.upcase}_SUBSCRIPTION_AUTH"
      wrapped_command = if unset_vars.any?
        %(if [ "$#{env_flag}" = "1" ]; then env #{unset_vars.map { |var| "-u #{var}" }.join(" ")} #{command_prefix} "$1"; else #{command_prefix} "$1"; fi)
      else
        %(#{command_prefix} "$1")
      end

      script = if gemini_test_error_capture?
        <<~SH.squish
          tmp_output="$(mktemp)" &&
          tmp_error="$(mktemp)" &&
          before_report="$(ls -t /tmp/gemini-client-error-*.json 2>/dev/null | head -n 1 || true)" &&
          #{wrapped_command} >"$tmp_output" 2>"$tmp_error";
          status=$?;
          after_report="$(ls -t /tmp/gemini-client-error-*.json 2>/dev/null | head -n 1 || true)";
          if [ "$status" -eq 0 ] && grep -q "Error when talking to Gemini API" "$tmp_error"; then
            if [ -n "$after_report" ] && [ "$after_report" != "$before_report" ]; then
              cat "$after_report" 2>/dev/null || cat "$tmp_error" 2>/dev/null;
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
      else
        <<~SH.squish
          tmp_output="$(mktemp)" &&
          tmp_error="$(mktemp)" &&
          #{wrapped_command} >/dev/null 2>"$tmp_error";
          status=$?;
          if [ "$status" -eq 0 ]; then
            cat "$tmp_output" 2>/dev/null;
          else
            cat "$tmp_error" 2>/dev/null;
          fi;
          exit $status
        SH
      end

      [ "sh", "-c", script, "--", PROMPT ]
    end

    def kilocode_test_command?
      provider.provider_key == "kilocode"
    end

    def kilocode_test_command_wrapper
      unset_vars = ProviderSupport.subscription_auth_unset_vars.values.flatten.uniq
      unset_flags = unset_vars.map { |var| "-u #{var}" }.join(" ")
      command_prefix = shell_join_command(test_command_prefix)
      script = <<~SH.squish
        env #{unset_flags}
        timeout 20s #{command_prefix} "$1"
      SH
      [ "sh", "-c", script, "--", PROMPT ]
    end

    def provider_test_command_overrides
      harness_provider.test_command_overrides
    end

    def provider_test_unset_vars
      harness_provider.subscription_unset_vars
    end

    def codex_test_output_capture?
      provider_test_command_overrides.include?("--output-last-message")
    end

    def gemini_test_error_capture?
      provider.provider_key == "gemini"
    end

    def parse_provider_test_error(output)
      provider_error = harness_provider.parse_test_error(output: output)
      return provider_error if provider_error

      Tempfile.create([ "#{provider.provider_key}-client-error-", ".json" ]) do |file|
        file.write(output.to_s)
        file.flush
        harness_provider.parse_test_error(output: output, files: { report: file.path })
      end
    end

    def shell_join_command(tokens)
      tokens.map { |token| shell_escape_token(token) }.join(" ")
    end

    def shell_escape_token(token)
      value = token.to_s
      value.start_with?("$") ? value : Shellwords.escape(value)
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
