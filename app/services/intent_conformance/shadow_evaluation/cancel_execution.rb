# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Authorized cancellation half of the async reviewer execution (#4642).
    # `call` records the operator's request; the running executor honors it
    # between cases and the queued job honors it before starting, so the
    # currently-in-flight case (a paid reviewer invocation) is never killed
    # mid-call — cancellation lands on the next case boundary. `finalize`
    # is the single terminal transition both paths use: cancelled state,
    # reason, and a compiled report of the collected evidence. Remaining
    # cases simply have no run row; nothing is fabricated as evaluated.
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class CancelExecution
      Result = Data.define(:success, :error, :evaluation) do
        def success? = success
      end

      def self.call(...) = new(...).call

      def initialize(evaluation:)
        @evaluation = evaluation
      end

      def call
        return failure("reviewer execution is not queued or running for this evaluation") unless active_in_row?

        now = Time.current
        IntentConformanceShadowEvaluation.where(id: @evaluation.id)
          .update_all(cancel_requested_at: now, updated_at: now)
        @evaluation.cancel_requested_at = now
        log_requested
        Result.new(success: true, error: nil, evaluation: @evaluation)
      end

      # Fresh row read: the caller's instance may predate the queued claim
      # (an atomic update_all), so the persisted status is authoritative.
      def active_in_row?
        IntentConformanceShadowEvaluation.where(id: @evaluation.id).pick(:status)
          .then { |status| IntentConformanceShadowEvaluation::ACTIVE_EXECUTION_STATUSES.include?(status) }
      end

      # Terminal cancellation transition shared by the executor loop (between
      # cases) and the job's before-start check. Preserves every recorded run.
      def self.finalize(evaluation, reason:)
        evaluation.update!(status: "cancelled", cancelled_at: Time.current, last_failure_reason: reason)
        compile_available_report(evaluation)
        Rails.logger.info(
          message: "intent_conformance.shadow_execution_cancelled",
          project_id: evaluation.project_id,
          shadow_evaluation_id: evaluation.id,
          evaluated_count: evaluation.runs.where.not(verdict: "not_evaluated").count
        )
        evaluation
      end

      def self.compile_available_report(evaluation)
        IntentConformance::ShadowEvaluation::CompileReport.call(evaluation: evaluation) if evaluation.runs.exists?
      end

      private

      def log_requested
        Rails.logger.info(
          message: "intent_conformance.shadow_execution_cancel_requested",
          project_id: @evaluation.project_id,
          shadow_evaluation_id: @evaluation.id
        )
      end

      def failure(message)
        Result.new(success: false, error: message, evaluation: @evaluation)
      end
    end
  end
end
