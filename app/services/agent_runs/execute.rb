# frozen_string_literal: true

# Compatibility shim: ensure AuthenticationError exists for agent-harness
# versions older than 0.4.0 that may not define it.
if defined?(AgentHarness) && defined?(AgentHarness::Error) && !defined?(AgentHarness::AuthenticationError)
  AgentHarness::AuthenticationError = Class.new(AgentHarness::Error)
end

module AgentRuns
  # Executes an agent run using the agent-harness gem.
  #
  # Maps agent-harness responses to AgentRun model fields, handles errors
  # and timeouts, and tracks token usage.
  #
  # @example
  #   result = AgentRuns::Execute.call(agent_run: agent_run, prompt: "Fix the bug")
  #   result.success? # => true
  #   result.response  # => AgentHarness::Response
  class Execute
    # Maps AgentRun agent_type values to agent-harness provider symbols
    PROVIDER_MAP = {
      "claude_code" => :claude,
      "cursor" => :cursor,
      "codex" => :codex,
      "copilot" => :github_copilot,
      "aider" => :aider,
      "gemini" => :gemini,
      "opencode" => :opencode,
      "kilocode" => :kilocode
    }.freeze

    attr_reader :agent_run, :prompt, :timeout

    def initialize(agent_run:, prompt:, timeout: nil)
      @agent_run = agent_run
      @prompt = prompt
      @timeout = timeout
    end

    def self.call(...)
      new(...).call
    end

    def call
      validate!
      start_run
      response = execute_agent
      process_response(response)
      Result.new(success: true, response: response)
    rescue AgentHarness::AuthenticationError => e
      handle_auth_error(e)
    rescue AgentHarness::TimeoutError => e
      handle_timeout(e)
    rescue AgentHarness::Error => e
      handle_error(e)
    end

    private

    def validate!
      provider_name = PROVIDER_MAP[agent_run.agent_type]
      raise ArgumentError, "Unsupported agent type: #{agent_run.agent_type}" unless provider_name
    end

    def start_run
      agent_run.start!
      agent_run.log!("system", "Starting #{agent_run.agent_type} agent")
      agent_run.log!("system", "Prompt: #{prompt.truncate(500)}")
    end

    def execute_agent
      provider_name = PROVIDER_MAP[agent_run.agent_type]

      options = { provider: provider_name, dangerous_mode: true }
      options[:timeout] = timeout unless timeout.nil?

      AgentHarness.send_message(prompt, **options)
    end

    def process_response(response)
      agent_run.log!("stdout", response.output) if response.output.present?

      if response.error.present?
        agent_run.log!("stderr", response.error)
      end

      track_tokens(response)

      if response.success?
        agent_run.update!(
          status: "completed",
          completed_at: Time.current,
          duration_seconds: response.duration&.round
        )
      else
        agent_run.update!(
          status: "failed",
          completed_at: Time.current,
          error_message: response.error || "Agent exited with code #{response.exit_code}",
          duration_seconds: response.duration&.round
        )
      end
    end

    # Run-level aggregate token tracking from the agent harness response.
    # Uses request_type "run_summary" to distinguish from per-request records
    # created by the secrets proxy controller (request_type "agent").
    # Skips aggregate updates (agent_run/project counters and cost budgets)
    # because those are already handled per-request by the secrets proxy.
    def track_tokens(response)
      return unless response.tokens

      TokenUsageTracker.track(
        agent_run: agent_run,
        usage: {
          tokens_input: response.input_tokens || 0,
          tokens_output: response.output_tokens || 0,
          request_type: "run_summary"
        },
        update_aggregates: false
      )
    end

    def handle_auth_error(error)
      provider_name = PROVIDER_MAP[agent_run.agent_type]
      agent_run.auth_expire!(error: error.message, provider: provider_name.to_s)
      agent_run.log!("system", "Authentication expired for #{provider_name}")

      Result.new(success: false, error: error)
    end

    def handle_timeout(error)
      effective_timeout = timeout || AgentHarness.configuration.default_timeout
      agent_run.timeout!
      agent_run.update!(error_message: "Agent execution timed out after #{effective_timeout} seconds")
      agent_run.log!("system", "Execution timed out")

      Result.new(success: false, error: error)
    end

    def handle_error(error)
      agent_run.fail!(error: error.message)
      agent_run.log!("stderr", error.message)
      agent_run.log!("system", "Execution failed: #{error.class.name}")

      Result.new(success: false, error: error)
    end

    # Simple result object for execute outcomes
    class Result
      attr_reader :response, :error

      def initialize(success:, response: nil, error: nil)
        @success = success
        @response = response
        @error = error
      end

      def success?
        @success
      end

      def failure?
        !@success
      end
    end
  end
end
