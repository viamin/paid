# frozen_string_literal: true

module Guardrails
  # Unified handler for guardrail violations. When any guardrail is triggered
  # (loop detection, token limit, cost limit, time limit, anomaly), this
  # service pauses or terminates the agent run and sends alerts with
  # actionable context.
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
    include Rails.application.routes.url_helpers

    # Violation types where no human intervention is expected — the run should
    # transition directly to a terminal state instead of pausing.
    TERMINAL_VIOLATION_TYPES = %w[time_limit token_limit cost_limit no_progress token_budget].freeze

    # Maps a terminal violation type to the run status it should produce.
    # Most guardrails reuse the generic "timeout" status; token_budget gets a
    # dedicated status so budget terminations are distinguishable in metrics.
    TERMINAL_STATUS_FOR = {
      "token_budget" => "token_budget_exceeded"
    }.freeze

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
      if terminal_violation?
        handle_terminal_violation
      else
        handle_pausable_violation
      end
    end

    private

    attr_reader :agent_run, :violation_type, :details, :metrics

    def terminal_violation?
      TERMINAL_VIOLATION_TYPES.include?(violation_type)
    end

    def handle_terminal_violation
      context = build_violation_context
      timed_out = agent_run.timeout!(
        error: "guardrail: #{violation_type} — #{details}",
        status: terminal_status,
        guardrail_violation_type: violation_type,
        guardrail_context: context
      )

      return already_handled_result(context) unless timed_out

      log_violation(context)
      context = persist_execution_cleanup(context, stop_in_flight_execution)

      safe_publish_notification(context)

      Result.new(paused: false, violation_type: violation_type, context: context)
    end

    def terminal_status
      TERMINAL_STATUS_FOR[violation_type] || "timeout"
    end

    def handle_pausable_violation
      context = build_violation_context
      paused = agent_run.pause!(violation_type: violation_type, context: context)

      return already_handled_result(context) unless paused

      log_violation(context)
      context = persist_execution_cleanup(context, stop_in_flight_execution)

      safe_publish_notification(context)

      Result.new(paused: true, violation_type: violation_type, context: context)
    end

    def safe_publish_notification(context)
      publish_notification(context)
    rescue => e
      Rails.logger.error(
        message: "guardrails.notification_failed",
        agent_run_id: agent_run.id,
        violation_type: violation_type,
        error_class: e.class.name,
        error_message: e.message
      )
    end

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
      when "no_progress"
        "The run consumed significant input tokens without producing meaningful output. " \
          "Review agent configuration and check for prompt or context issues that prevent the agent from generating a response."
      when "token_budget"
        "The run exceeded its per-run input token budget without producing meaningful output. " \
          "Review the project/provider token budget and check for prompt or context issues that prevent the agent from generating a response."
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

    def stop_in_flight_execution
      AgentRuns::Cancel.call(agent_run: agent_run, skip_status_update: true)
      { status: "cancelled", attempted_at: Time.current.iso8601 }
    rescue => e
      Rails.logger.error(
        message: "guardrails.violation_pause_cancel_failed",
        agent_run_id: agent_run.id,
        violation_type: violation_type,
        error_class: e.class.name,
        error_message: e.message
      )
      {
        status: "cancel_failed",
        attempted_at: Time.current.iso8601,
        error_class: e.class.name,
        error_message: e.message
      }
    end

    def persist_execution_cleanup(context, cleanup_result)
      updated_context = context.merge(execution_cleanup: cleanup_result)
      agent_run.update!(guardrail_context: updated_context)
      updated_context
    end

    def publish_notification(context)
      Notifications::Publish.call(
        account: agent_run.project.account,
        source: "guardrail_#{violation_type}",
        subject: agent_run,
        severity: notification_severity,
        blocking: blocking_notification?,
        title: notification_title,
        description: details,
        metadata: {
          violation_type: violation_type,
          project_id: agent_run.project_id,
          agent_type: agent_run.agent_type,
          trigger_type: agent_run.trigger_type,
          metrics: context[:metrics],
          recommended_action: context[:recommended_action],
          triggered_at: context[:triggered_at]
        },
        action_url: notification_action_url,
        nav_section: "agent_runs"
      )
    end

    def notification_severity
      :error
    end

    def notification_title
      action = terminal_violation? ? "terminated" : "paused"
      "Agent run ##{agent_run.id} #{action} by #{violation_type.tr("_", " ")} guardrail"
    end

    def blocking_notification?
      violation_type == "token_budget" && (
        agent_run.count_toward_draft_review_round? ||
        agent_run.trigger_type == "pull_request"
      )
    end

    def notification_action_url
      return if blocking_notification?

      project_agent_run_path(agent_run.project, agent_run)
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

    def already_handled_result(context)
      AlreadyHandledResult.new(
        paused: agent_run.paused?,
        violation_type: agent_run.guardrail_violation_type || violation_type,
        context: agent_run.guardrail_context || context
      )
    end
  end
end
