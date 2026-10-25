# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Authorizes one durable reviewer execution. Repeated submissions share the
    # same evaluation and never create a second expensive run.
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class QueueReviewer
      Result = Data.define(:success, :error, :evaluation, :enqueued) do
        def success? = success
      end

      def self.call(...) = new(...).call

      def initialize(evaluation:)
        @evaluation = evaluation
      end

      def call
        evaluation.with_lock do
          return failure("reviewer execution requires a frozen reference label set") unless evaluation.answers_visible?
          return success(false) if evaluation.execution_active?

          evaluation.update!(status: "queued", cancellation_requested_at: nil, cancelled_at: nil,
            last_failure_reason: nil, execution_heartbeat_at: Time.current)
        end
        ExecuteReviewerJob.perform_later(evaluation.project_id, evaluation.id)
        success(true)
      end

      private

      attr_reader :evaluation

      def success(enqueued)
        Result.new(success: true, error: nil, evaluation:, enqueued:)
      end

      def failure(error)
        Result.new(success: false, error:, evaluation:, enqueued: false)
      end
    end
  end
end
