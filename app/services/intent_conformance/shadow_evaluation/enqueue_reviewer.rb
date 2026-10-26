# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Authorizes one durable execution request. GoodJob owns delivery and the
    # job owns the expensive reviewer work, so a web request never waits on a
    # provider response.
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class EnqueueReviewer
      Result = Data.define(:success, :error, :evaluation, :resumed) do
        def success? = success
      end

      def self.call(...) = new(...).call

      def initialize(evaluation:)
        @evaluation = evaluation
      end

      def call
        return failure("reviewer execution requires a frozen reference label set") unless evaluation.answers_visible?
        return failure("corpus manifest changed since reference labels were frozen — start a new evaluation") unless evaluation.corpus.matches_recorded_digest?
        return Result.new(success: true, error: nil, evaluation: evaluation, resumed: true) if evaluation.queued? || evaluation.running?

        evaluation.update!(status: "queued", cancel_requested_at: nil, cancelled_at: nil, last_failure_reason: nil)
        IntentConformance::ShadowEvaluationJob.perform_later(evaluation.project_id, evaluation.id)
        Result.new(success: true, error: nil, evaluation: evaluation, resumed: false)
      rescue ShadowEvaluationCorpus::MissingManifest => error
        failure(error.message)
      end

      private

      attr_reader :evaluation

      def failure(error)
        Result.new(success: false, error: error, evaluation: evaluation, resumed: false)
      end
    end
  end
end
