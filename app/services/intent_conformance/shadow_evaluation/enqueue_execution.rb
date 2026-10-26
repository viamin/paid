# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Persists the intent to execute before handing work to Active Job. The row
    # lock makes repeated UI/API submissions idempotent without relying on the
    # adapter's delivery semantics.
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class EnqueueExecution
      Result = Data.define(:success, :error, :enqueued) do
        def success? = success
        def enqueued? = enqueued
      end

      def self.call(...) = new(...).call

      def initialize(evaluation:)
        @evaluation = evaluation
      end

      def call
        return failure("reviewer execution requires a frozen reference label set") unless evaluation.answers_visible?
        return failure("corpus manifest changed since reference labels were frozen — start a new evaluation") unless evaluation.corpus.matches_recorded_digest?

        queued = evaluation.with_lock do
          next false if evaluation.queued? || evaluation.running?

          evaluation.update!(status: "queued", last_failure_reason: nil)
          true
        end
        IntentConformanceShadowEvaluationJob.perform_later(evaluation.id) if queued
        Result.new(success: true, error: nil, enqueued: queued)
      end

      private

      attr_reader :evaluation

      def failure(error)
        Result.new(success: false, error:, enqueued: false)
      end
    end
  end
end
