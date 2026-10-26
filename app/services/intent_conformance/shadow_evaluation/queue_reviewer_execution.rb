# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Authorizes one idempotent background execution. The worker retains the
    # existing reviewer service, so corpus identity, blinding, budgets, and
    # per-case deduplication remain owned by their current code paths.
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class QueueReviewerExecution
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

        enqueue = evaluation.with_lock { queue! }
        ExecuteJob.perform_later(evaluation.id) if enqueue
        Result.new(success: true, error: nil, enqueued: enqueue)
      end

      private

      attr_reader :evaluation

      def queue!
        return false if evaluation.queued? || evaluation.running?
        return false if evaluation.completed?

        evaluation.update!(status: "queued", cancel_requested_at: nil, cancelled_at: nil, last_failure_reason: nil)
        true
      end

      def failure(error)
        Result.new(success: false, error:, enqueued: false)
      end
    end
  end
end
