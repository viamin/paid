# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Authorize-and-enqueue half of the async reviewer execution (#4642):
    # the HTTP request (or documented command) only claims the queued state
    # and enqueues the idempotent ExecuteJob — the corpus is never executed
    # inside the request. The status claim is an atomic conditional update,
    # so duplicate submissions (double click, retry storm) cannot enqueue a
    # second execution; the executor's advisory lock and evaluated-verdict
    # skip keep any residual duplicate free of repeated spend. The freeze
    # gate is re-checked here so blinding is preserved at the request
    # boundary; corpus digest and reviewer-identity validation stay with the
    # executor, which owns the authoritative checks.
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class EnqueueExecution
      Result = Data.define(:success, :error, :evaluation) do
        def success? = success
      end

      def self.call(...) = new(...).call

      def initialize(evaluation:)
        @evaluation = evaluation
      end

      def call
        return failure("reviewer execution requires a frozen reference label set") unless @evaluation.answers_visible?
        return failure("reviewer execution is already queued or running for this evaluation") if @evaluation.execution_active?

        unless claim_queued!
          Rails.logger.info(
            message: "intent_conformance.shadow_evaluation_enqueue_contended",
            project_id: @evaluation.project_id,
            shadow_evaluation_id: @evaluation.id
          )
          return failure("reviewer execution is already queued or running for this evaluation")
        end

        IntentConformance::ShadowEvaluations::ExecuteJob.perform_later(@evaluation.id)
        Result.new(success: true, error: nil, evaluation: @evaluation)
      end

      private

      # Atomic idle→queued transition: only one concurrent request can flip
      # the status, and a fresh claim always clears a prior cancellation
      # request so the new run is not insta-cancelled by a stale flag.
      # `cancel_requested_at`/`cancelled_at` from an earlier lifecycle are
      # historical once the new run starts; `cancelled_at` is retained as
      # evidence of the earlier cancellation.
      def claim_queued!
        now = Time.current
        IntentConformanceShadowEvaluation.where(id: @evaluation.id, status: IntentConformanceShadowEvaluation::IDLE_EXECUTION_STATUSES)
          .update_all(status: "queued", execute_queued_at: now, execute_heartbeat_at: nil, cancel_requested_at: nil, updated_at: now)
          .positive?
      end

      def failure(message)
        Result.new(success: false, error: message, evaluation: @evaluation)
      end
    end
  end
end
