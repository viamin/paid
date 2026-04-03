# frozen_string_literal: true

module Guardrails
  # Unified handler for guardrail violations. When any guardrail is triggered
  # (loop detection, token limit, cost limit, time limit, anomaly), this
  # service pauses the agent run and sends alerts with actionable context.
  #
  # @example
  #   result = Guardrails::ViolationHandler.call(
  #     agent_run: agent_run,
  #     violation_type: "loop_detected",
  #     details: "5 consecutive identical outputs",
  #     metrics: { iterations: 42, tokens_used: 15000 }
  #   )
  #   result.paused?       # => true
  #   result.violation_type # => "loop_detected"
  class ViolationHandler
    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:, violation_type:, details:, metrics: {})
      @agent_run = agent_run
      @violation_type = violation_type
      @details = details
      @metrics = metrics

      validate_inputs!
    end

    def call
      context = build_violation_context
      paused = agent_run.pause!(violation_type: violation_type, context: context)

      return already_handled_result unless paused

      log_violation(context)

      # Dashboard alert is handled by LiveDashboardBroadcastJob (triggered by
      # the status change callback) to avoid duplicate notifications.

      Result.new(paused: true, violation_type: violation_type, context: context)
    end

    private

    attr_reader :agent_run, :violation_type, :details, :metrics

    def validate_inputs!
      unless AgentRun::GUARDRAIL_VIOLATION_TYPES.include?(violation_type)
        raise ArgumentError, "Unknown violation type: #{violation_type}"
      end
    end

    def build_violation_context
      {
        violation_type: violation_type,
        details: details,
        triggered_at: Time.current.iso8601,
        metrics: current_metrics.merge(metrics),
        recommended_action: recommended_action
      }
    end

    def current_metrics
      {
        iterations: agent_run.iterations,
        tokens_input: agent_run.tokens_input,
        tokens_output: agent_run.tokens_output,
        cost_cents: agent_run.cost_cents,
        duration_seconds: agent_run.duration
      }
    end

    def recommended_action
      case violation_type
      when "loop_detected"
        "Review agent output for repeated patterns. Consider adjusting the prompt or terminating if the agent is stuck."
      when "token_limit"
        "Token usage has exceeded the configured limit. Review output quality and consider terminating or increasing the limit."
      when "cost_limit"
        "Cost budget has been exceeded. Review spending and consider adjusting budget limits or terminating the run."
      when "time_limit"
        "Execution time has exceeded the configured limit. The agent may need more time or the task may be too complex."
      when "anomaly"
        "Unusual behavior detected. Review agent metrics and output for unexpected patterns."
      end
    end

    def log_violation(context)
      agent_run.log!("system", "Guardrail violation: #{violation_type} - #{details}")

      Rails.logger.warn(
        message: "guardrails.violation_detected",
        agent_run_id: agent_run.id,
        project_id: agent_run.project_id,
        violation_type: violation_type,
        details: details,
        triggered_at: context[:triggered_at],
        metrics: context[:metrics],
        recommended_action: context[:recommended_action]
      )
    end

    class Result
      attr_reader :violation_type, :context

      def initialize(paused:, violation_type:, context:)
        @paused = paused
        @violation_type = violation_type
        @context = context
      end

      def paused?
        @paused
      end
    end

    class AlreadyHandledResult
      def paused?
        false
      end

      def violation_type
        nil
      end

      def context
        nil
      end
    end

    def already_handled_result
      AlreadyHandledResult.new
    end
  end
end
