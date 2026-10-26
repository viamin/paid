# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # @spec INTENT-CONFORMANCE-ROLLOUT-007 @spec INTENT-CONFORMANCE-ROLLOUT-009
    class EnqueueReviewer
      Result = Data.define(:success, :error, :evaluation, :enqueued) do
        def success? = success
      end

      def self.call(...) = new(...).call

      def initialize(evaluation:) = @evaluation = evaluation

      def call
        return failure("reviewer execution requires a frozen reference label set") unless evaluation.answers_visible?

        evaluation.with_lock do
          return Result.new(success: true, error: nil, evaluation:, enqueued: false) if evaluation.queued? || evaluation.running?
          return failure("corpus manifest changed since reference labels were frozen — start a new evaluation") unless evaluation.corpus.matches_recorded_digest?

          evaluation.update!(status: "queued", execution_requested_at: Time.current, cancel_requested_at: nil, last_failure_reason: nil)
        end
        ShadowEvaluationReviewerJob.perform_later(evaluation.id)
        Result.new(success: true, error: nil, evaluation:, enqueued: true)
      end

      private

      attr_reader :evaluation

      def failure(error) = Result.new(success: false, error:, evaluation:, enqueued: false)
    end
  end
end
