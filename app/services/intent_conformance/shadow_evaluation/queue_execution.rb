# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Authorizes durable execution work without holding an HTTP request open.
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class QueueExecution
      Result = Data.define(:success, :error, :evaluation, :enqueued) do
        def success? = success
      end

      def self.call(...) = new(...).call

      def initialize(evaluation:)
        @evaluation = evaluation
      end

      def call
        return failure("reviewer execution requires a frozen reference label set") unless evaluation.answers_visible?

        enqueue = evaluation.with_lock { queue! }
        IntentConformance::ShadowEvaluationExecutionJob.perform_later(evaluation.id) if enqueue
        Result.new(success: true, error: nil, evaluation:, enqueued: enqueue)
      end

      private

      attr_reader :evaluation

      def queue!
        return false if evaluation.queued? || evaluation.running?

        evaluation.update!(status: "queued", cancellation_requested_at: nil, last_failure_reason: nil)
        true
      end

      def failure(error)
        Result.new(success: false, error:, evaluation: nil, enqueued: false)
      end
    end
  end
end
