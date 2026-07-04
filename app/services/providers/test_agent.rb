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
      /\bauth(?:entication)?\b/i,
      /oauth/i,
      # Token-auth patterns — split for readability. Each pattern requires
      # "token" adjacent to an auth-specific qualifier (expired/revoked/invalid/
      # not found), so unrelated uses like "CSRF token" or "unexpected token"
      # naturally fall through without matching.
      /token\s+(?:expired|revoked|invalid|not found)/i,
      /(?:invalid|expired|revoked)\s+token/i,
      /api[_ -]?key.*token/i,
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
      /Model not found:.*?(?=\n|$)/i,
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

    # Matches any GitHub Copilot session lifecycle event (e.g. session.shutdown,
    # session.mcp_server_status_changed, session.mcp_servers_loaded). Used both
    # to filter these events out of cleaned smoke-test output AND to detect the
    # "only lifecycle events, no response" case so the fallback message can fire.
    # Keeping a single broad pattern avoids missing new event variants the
    # Copilot CLI adds (the original strict alternation missed
    # session.mcp_servers_loaded).
    MCP_SESSION_EVENT_PATTERN = /"type"\s*:\s*"session\./

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

    def initialize(provider:, diagnostic_prompt: nil, diagnostic_timeout: nil, diagnostic_success_pattern: nil)
      @provider = provider
      @diagnostic_prompt = diagnostic_prompt
      @diagnostic_timeout = diagnostic_timeout
      @diagnostic_success_pattern = diagnostic_success_pattern
    end

    def self.call(...)
      new(...).call
    end

    def call
      validate!
      result =
        if @diagnostic_prompt
          # Diagnostic path bypasses the harness smoke contract so callers can
          # exercise specific subsystems (tool use, MCP) with a custom prompt.
          # Always container-backed (host path skipped) so timing and heartbeat
          # behaviour match real agent runs.
          execute_container_diagnostic
        elsif harness_health_check_supported?
          execute_harness_health_check_with_fallback
        else
          execute_container_smoke_test
        end

      update_provider_state!(result) unless @diagnostic_prompt
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
      unless ProviderSupport.supported_provider_key?(effective_provider.provider_key)
        raise UnsupportedProviderError, "Unknown provider: #{effective_provider.provider_key}"
      end

      unless ProviderSupport.container_executable_provider_key?(effective_provider.provider_key)
        raise NotContainerExecutableError,
          "Provider #{effective_provider.provider_key} is not installed in the agent container"
      end

      return if harness_health_check_supported? && !@diagnostic_prompt

      raise MissingProjectContextError, "Add a project before testing providers in the agent container" unless test_project
    end

    # Runs a custom prompt against the provider's agent inside a provisioned
    # container, then evaluates the response against an optional success
    # pattern. Used by diagnostic smoke scenarios that need to exercise
    # specific subsystems (tool use, MCP, longer prompts) instead of the
    # fixed "Reply OK" smoke contract. Returns a Result with timing info in
    # the message so the smoke runner can compare scenarios side-by-side.
    def execute_container_diagnostic
      test_run = build_test_run
      timeout = @diagnostic_timeout || TIMEOUT

      begin
        test_run.with_container do |run|
          executor = Containers::HarnessExecutor.new(run)
          prepare_kilocode_config!(run) if kilocode_direct_outbound?

          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          response = AgentHarness.send_message(
            @diagnostic_prompt,
            provider: harness_provider_name,
            executor: executor,
            provider_runtime: container_provider_runtime,
            timeout: timeout
          )
          elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round

          process_diagnostic_response(response, elapsed_ms: elapsed_ms)
        end
      ensure
        test_run.destroy! if test_run&.persisted?
      end
    end

    def process_diagnostic_response(response, elapsed_ms:)
      # AgentHarness::Response exposes #output, #error, #success?, #failed?,
      # #exit_code, #total_tokens. Read those directly — earlier versions of
      # this method probed for #content via respond_to?, which silently
      # fell through to #to_s and matched no success pattern.
      output = normalize_output_text(response.output).to_s.strip
      tokens = response.total_tokens
      summary = "elapsed=#{elapsed_ms}ms tokens=#{tokens || "n/a"} output=#{output[0, 200].inspect}"

      if response.failed?
        message = normalize_output_text(response.error).presence || "diagnostic failed (exit #{response.exit_code})"
        return Result.new(success: false, error_type: :unexpected, message: "#{message} (#{summary})")
      end

      if @diagnostic_success_pattern && !@diagnostic_success_pattern.match?(output)
        return Result.new(success: false, error_type: :unexpected,
          message: "diagnostic output did not match #{@diagnostic_success_pattern.inspect} (#{summary})")
      end

      Result.new(success: true, error_type: nil, message: "Diagnostic passed (#{summary})")
    end

    include TestAgentHealthCheckFallback

    def harness_health_check_key
      harness_provider_name
    end

    def harness_fallback_log_prefix
      "providers.test_agent"
    end

    def harness_fallback_log_context
      { provider_key: effective_provider.provider_key }
    end

    def execute_harness_health_check
      AgentHarness.check_provider(harness_provider_name, timeout: TIMEOUT)
    end

    def process_harness_result(result)
      status = result[:status].to_s
      message = normalize_output_text(result[:message]).presence
      output = normalize_output_text(result[:output]).presence
      harness_error_type = map_harness_error_category(result[:error_category])
      preferred_failure_message = preferred_failure_display_message(message, output)
      display_message = preferred_failure_message ||
        message || output || "Provider health check returned no message"
      classification_message = [ message, output ].compact.uniq.join("\n")
      failure_message = preferred_failure_message || classification_message.presence || display_message

      if smoke_test_failure_output?(classification_message)
        translated_message = translate_and_extract_error(failure_message)
        error_type = resolve_error_type(
          harness_error_type: harness_error_type,
          message: translated_message.presence || failure_message
        )

        Result.new(
          success: false,
          error_type: error_type,
          message: translated_message.presence || display_message
        )
      elsif harness_error_type.present? && (!smoke_test_output_success?(output) || !smoke_test_output_success?(message))
        translated_message = translate_and_extract_error(failure_message)

        Result.new(
          success: false,
          error_type: resolve_error_type(
            harness_error_type: harness_error_type,
            message: translated_message.presence || failure_message
          ),
          message: translated_message.presence || display_message
        )
      elsif smoke_test_output_success?(output) || smoke_test_output_success?(message)
        Result.new(success: true, error_type: nil, message: "Agent is healthy")
      elsif status == "ok"
        Result.new(success: true, error_type: nil, message: "Agent is healthy")
      else
        translated_message = translate_and_extract_error(failure_message)
        error_type = resolve_error_type(
          harness_error_type: harness_error_type,
          message: translated_message.presence || failure_message
        )

        Result.new(
          success: false,
          error_type: error_type,
          message: translated_message.presence || display_message
        )
      end
    end

    def smoke_test_output_success?(text)
      text.to_s.strip.match?(/\AOK[.!]?\z/i)
    end

    def preferred_failure_display_message(message, output)
      return output if smoke_test_output_success?(message) && !smoke_test_output_success?(output) && output.present?
      return message if smoke_test_output_success?(output) && !smoke_test_output_success?(message) && message.present?

      nil
    end

    def smoke_test_failure_output?(text)
      message = sanitize_error_message(text)
      return false if message.empty?
      return true if message.match?(/Model not found:/i)

      classify_failed_response(message) != :unexpected
    end

    def map_harness_error_category(category)
      return nil unless category

      HARNESS_ERROR_CATEGORY_MAP[category.to_sym]
    end

    def resolve_error_type(harness_error_type:, message:)
      classified_error_type = classify_failed_response(message)
      return :unexpected if message.match?(/Model not found:/i)
      return classified_error_type if harness_error_type.nil? || harness_error_type == :unexpected
      return classified_error_type if harness_error_type == :rate_limited &&
        classified_error_type != :rate_limited &&
        classified_error_type != :unexpected

      harness_error_type
    end

    # Builds a ProviderRuntime for container-based smoke tests.
    #
    # For direct-outbound providers (e.g. opencode with API key), this returns
    # the provider's full runtime with env/base_url overrides. For kilocode
    # direct-outbound, this builds a runtime with the upstream API key env
    # (config file bootstrap is handled by prepare_kilocode_config!).
    # For subscription-auth providers, this strips the Paid proxy credential
    # env vars so the CLI uses its mounted local auth state, matching the
    # behavior of RunAgentActivity.subscription_auth_command.
    def container_provider_runtime
      return kilocode_provider_runtime if kilocode_direct_outbound?
      return subscription_provider_runtime if subscription_provider_runtime?

      effective_provider.agent_harness_provider_runtime
    end

    def subscription_provider_runtime?
      effective_provider.subscription? &&
        ProviderSupport.subscription_auth_unset_vars_for(effective_provider.provider_key).any?
    end

    def subscription_provider_runtime
      unset_vars = ProviderSupport.subscription_auth_unset_vars_for(effective_provider.provider_key)

      if effective_provider.provider_key == "copilot"
        unset_vars.delete("COPILOT_GITHUB_TOKEN")
      end

      AgentHarness::ProviderRuntime.new(unset_env: unset_vars)
    end

    # Builds a ProviderRuntime for kilocode direct-outbound smoke tests.
    #
    # Kilocode reads its model/provider config from ~/.config/kilo/config.json
    # (materialized by prepare_kilocode_config!) and picks up the upstream API
    # key from environment variables. This runtime passes the API key through
    # the env var referenced by the generated config.
    def kilocode_provider_runtime
      AgentHarness::ProviderRuntime.new(env: effective_provider.kilocode_runtime_env)
    end

    def kilocode_direct_outbound?
      effective_provider.provider_key == "kilocode" && effective_provider.requires_direct_outbound?
    end

    # Writes the kilocode config file into the container before the smoke test.
    #
    # Uses a direct container exec instead of ExecutionPreparation because
    # ExecutionPreparation cleans up files after each execute call (see
    # provision.rb ensure block), which removes the config before the
    # subsequent smoke test runs.
    def prepare_kilocode_config!(run)
      config_json = effective_provider.kilocode_config_json
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
      # The row is destroyed as soon as the container test completes, but the
      # project counter cache still needs to stay accurate while it exists.
      now = Time.current
      AgentRun.transaction do
        result = AgentRun.insert_all!(
          [ {
            project_id: test_project.id,
            initiating_user_id: effective_provider.user_id,
            runner_id: effective_provider.id,
            agent_type: Provider.agent_type_for(effective_provider.provider_key),
            status: "queued",
            temporal_workflow_id: AgentRun::CLAIMED_SENTINEL,
            goal: "create_pr",
            trigger_type: "manual",
            custom_prompt: AgentRun::SMOKE_TEST_CUSTOM_PROMPT,
            proxy_token: SecureRandom.hex(32),
            created_at: now,
            updated_at: now
          } ],
          returning: [ :id ]
        )
        Project.update_counters(test_project.id, agent_runs_count: 1)
        AgentRun.find(result.first["id"])
      end
    end

    def test_project
      @test_project ||= effective_provider.user.created_projects.active.order(:id).first ||
        effective_provider.user.member_projects.active.order(:id).first
    end

    def harness_health_check_supported?
      return false if effective_provider.subscription?
      api_key_name = ProviderSupport.proxy_health_check_api_key_for(effective_provider.provider_key)
      !!(api_key_name && proxy_api_key_configured?(api_key_name))
    end

    def harness_provider_name
      ProviderSupport.harness_provider_key_for(effective_provider.provider_key).to_sym
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
        effective_provider.user.runner_states.find_by(runner_name: provider_name)&.record_success!(force_close: true)
      end
    end

    def persist_rate_limited_state!(message)
      reset_at = rate_limit_reset_at(message)

      provider_state_names.each do |provider_name|
        effective_provider.user.runner_states.find_or_create_by!(runner_name: provider_name).mark_rate_limited!(reset_at: reset_at)
      end
    rescue ActiveRecord::RecordNotUnique
      provider_state_names.each do |provider_name|
        effective_provider.user.runner_states.find_by!(runner_name: provider_name).mark_rate_limited!(reset_at: reset_at)
      end
    end

    def provider_state_names
      names = [ effective_provider.state_key ]
      if effective_provider.subscription? || effective_provider.state_key == effective_provider.provider_key
        names << effective_provider.provider_key
      end

      names.uniq
    end

    def effective_provider
      @effective_provider ||= materialize_account_provider || provider
    end

    def materialize_account_provider
      return if provider.api_key?

      credential = LlmCredentials::AccountResolver.call(
        account: provider.user.account,
        runner_key: provider.provider_key,
        api_service_type: provider.required_api_service_type,
        tenant_setting: provider.user.account.tenant_setting
      )
      return unless credential.present?

      provider.user.providers.kept_only.find_or_create_by!(
        provider_key: provider.provider_key,
        auth_type: "api_key",
        provider_api_key: credential.provider_api_key,
        integration_credential: credential.integration_credential
      ) do |record|
        record.config = account_managed_provider_config(credential)
        record.enabled_for_agent_runs = provider.enabled_for_agent_runs
        record.enabled_for_fallback = provider.enabled_for_fallback
        record.fallback_role = provider.fallback_role
      end.tap do |record|
        config = account_managed_provider_config(credential)
        record.update!(config: config) if config != record.config
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      provider.user.providers.kept_only.find_by(
        provider_key: provider.provider_key,
        auth_type: "api_key",
        provider_api_key: credential&.provider_api_key,
        integration_credential: credential&.integration_credential
      )
    end

    def account_managed_provider_config(credential)
      return provider.config unless provider.provider_key == "pi"

      provider.config.deep_dup.tap do |config|
        config["pi"] ||= {}
        config["pi"]["api_provider"] = credential.provider_api_key&.api_service_type || provider.required_api_service_type
      end
    end

    def rate_limit_reset_at(message)
      ProviderSupport.rate_limit_reset_at(harness_provider, message)
    end

    def harness_provider
      AgentHarness.provider(harness_provider_name)
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

      classified_line = cleaned_lines.find do |line|
        line.match?(/Model not found:/i) || classify_failed_response(line) != :unexpected
      end
      return classified_line if classified_line

      cleaned_lines.first || fallback_message_from(message)
    end

    def fallback_message_from(raw_message)
      lines = raw_message.lines.map(&:strip).reject(&:empty?)
      if lines.any? && lines.all? { |line| line.match?(MCP_SESSION_EVENT_PATTERN) }
        "Agent started but did not produce a response. Verify the provider credentials and connectivity."
      else
        lines.first.to_s.strip
      end
    end

    def matches_any_pattern?(message, patterns)
      message = sanitize_error_message(message)
      patterns.any? { |pattern| pattern.match?(message) }
    end

    def noisy_error_line?(line)
      return true if line.match?(MCP_SESSION_EVENT_PATTERN)

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

      if message.match?(/exec:\s*"(?:github-copilot-cli|copilot)": executable file not found in \$PATH/i)
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
