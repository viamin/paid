# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Durable admission boundary for reviewer execution. It records intent
    # before enqueueing so duplicate HTTP/API submissions share one operation.
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class QueueExecution
      Result = Data.define(:success, :error, :evaluation, :enqueued) do
        def success? = success
      end

      STALE_AFTER = 15.minutes

      def self.call(...) = new(...).call

      def initialize(evaluation:, job_class: IntentConformance::ShadowEvaluationJob)
        @evaluation = evaluation
        @job_class = job_class
      end

      def call
        return failure("reviewer execution requires a frozen reference label set") unless evaluation.answers_visible?
        return failure("corpus manifest changed since reference labels were frozen — start a new evaluation") unless evaluation.corpus.matches_recorded_digest?

        evaluation.with_lock do
          evaluation.reload
          return success(false) if active_and_fresh?

          evaluation.update!(status: "queued", execution_requested_at: Time.current,
            execution_cancelled_at: nil, execution_heartbeat_at: Time.current, last_failure_reason: nil)
        end
        job_class.perform_later(evaluation.id)
        success(true)
      end

      private

      attr_reader :evaluation, :job_class

      def active_and_fresh?
        evaluation.executing? && evaluation.execution_heartbeat_at.present? && evaluation.execution_heartbeat_at > STALE_AFTER.ago
      end

      def success(enqueued) = Result.new(success: true, error: nil, evaluation:, enqueued:)
      def failure(error) = Result.new(success: false, error:, evaluation: nil, enqueued: false)
    end
  end
end
