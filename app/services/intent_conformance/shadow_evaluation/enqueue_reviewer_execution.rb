# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Authorizes one durable, idempotent reviewer-execution request. The job,
    # not the HTTP request, owns provider I/O and report compilation.
    # @spec INTENT-CONFORMANCE-ROLLOUT-007
    # @spec INTENT-CONFORMANCE-ROLLOUT-009
    class EnqueueReviewerExecution
      Result = Data.define(:success, :error, :enqueued) do
        def success? = success
      end

      def self.call(...) = new(...).call

      def initialize(evaluation:)
        @evaluation = evaluation
      end

      def call
        return failure("reviewer execution requires a frozen reference label set") unless evaluation.answers_visible?
        return failure("corpus manifest changed since reference labels were frozen — start a new evaluation") unless evaluation.corpus.matches_recorded_digest?
        return Result.new(success: true, error: nil, enqueued: false) if evaluation.queued? || evaluation.running?

        evaluation.update!(status: "queued", execution_requested_at: Time.current, execution_cancelled_at: nil,
          last_failure_reason: nil)
        ShadowEvaluationExecutionJob.perform_later(evaluation.project_id, evaluation.id)
        ShadowEvaluationExecutionRecoveryJob.set(wait: 15.minutes).perform_later(evaluation.project_id, evaluation.id)
        Result.new(success: true, error: nil, enqueued: true)
      end

      private

      attr_reader :evaluation

      def failure(error) = Result.new(success: false, error:, enqueued: false)
    end
  end
end
