# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Authorizes a durable reviewer operation without doing provider work in
    # the request. A later click may enqueue another delivery, but both the
    # GoodJob key and ExecuteReviewer's advisory lock make actual execution
    # idempotent for this evaluation identity.
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class EnqueueReviewer
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

        evaluation.with_lock do
          evaluation.update!(status: "queued", cancel_requested_at: nil, cancelled_at: nil, last_failure_reason: nil)
        end
        IntentConformance::ShadowEvaluationJob.perform_later(evaluation.project_id, evaluation.id)
        Result.new(success: true, error: nil, enqueued: true)
      rescue ActiveRecord::RecordInvalid => error
        failure(error.message)
      end

      private

      attr_reader :evaluation

      def failure(error)
        Result.new(success: false, error: error, enqueued: false)
      end
    end
  end
end
