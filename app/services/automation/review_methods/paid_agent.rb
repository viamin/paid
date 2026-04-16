# frozen_string_literal: true

module Automation
  module ReviewMethods
    # Paid Agent review — Paid's first-party review agent, run via the
    # Temporal +agent_execution+ workflow with +goal=review+.
    #
    # Distinctive properties:
    #
    # * Body-only review (no inline threads); clean runs mark themselves with
    #   the paid-review clean marker.
    # * Has a retry budget (+max_review_goal_retries+) on top of the per-PR
    #   review round cap (+max_review_rounds+). A failed review run is a
    #   retryable failure until the budget is spent.
    # * When +paid_agent+ is the sole enabled review method, a pending
    #   outcome is a hard block on draft→ready progression. With other
    #   methods enabled, the outcome is a non-blocking sidecar so the PR
    #   can continue to accumulate feedback from other reviewers in
    #   parallel.
    class PaidAgent < Base
      TRIGGER_TYPE = "paid_agent_review_pending"
      RETRY_TRIGGER_TYPE = "review_goal_retry"
      ESCALATE_TRIGGER_TYPE = "escalate_to_owner"

      def kind = :agent

      def blocking_by_default?
        config.paid_agent_sole_method?
      end

      def evaluate
        if signals.trigger?(RETRY_TRIGGER_TYPE)
          return outcome_retryable_failure(
            blocking: blocking_by_default?,
            message: "paid_agent review failed; retrying within budget",
            metadata: { retry_count: signals.review_goal_retry_count }
          )
        end

        pending = signals.trigger(TRIGGER_TYPE)
        if pending
          return outcome_pending(
            blocking: blocking_by_default?,
            message: pending_message(pending),
            metadata: {
              active_run: pending[:active_run] == true,
              sole_method: config.paid_agent_sole_method?
            }
          )
        end

        return outcome_not_applicable unless config.method_enabled?(:paid_agent)

        if exhausted?
          return outcome_exhausted_retries(message: "paid_agent retry budget exhausted")
        end

        outcome_satisfied
      end

      # Paid agent methods queue a review run whenever the scan indicates a
      # pending paid_agent review (and no run is already active) or a
      # review-goal retry is due. This mirrors the behavior previously
      # encoded in +Automation::PullRequestEvaluator+ and trusts the scan
      # to only emit the triggers when the method is actually enabled.
      def decision
        return nil unless should_queue_review_run?

        Automation::Decision.queue_review_run(
          issue_id: signals.issue_id,
          source_pull_request_number: signals.pr_number
        )
      end

      private

      def should_queue_review_run?
        return true if signals.trigger?(RETRY_TRIGGER_TYPE)

        pending = signals.trigger(TRIGGER_TYPE)
        return false unless pending

        pending[:active_run] != true
      end

      def pending_message(trigger)
        if trigger[:active_run]
          "paid_agent review already running"
        else
          "paid_agent review requested"
        end
      end

      def exhausted?
        escalate = signals.trigger(ESCALATE_TRIGGER_TYPE)
        escalate && escalate[:reason].to_s.include?("paid_agent")
      end
    end
  end
end
