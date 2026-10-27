# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Authorization happens in the controller/API policy. This service owns
    # the idempotent state transition and enqueue boundary.
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class EnqueueExecution
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

        enqueued = evaluation.queue_execution!
        ShadowEvaluationExecutionJob.perform_later(evaluation.project_id, evaluation.id) if enqueued
        Result.new(success: true, error: nil, enqueued: enqueued)
      rescue StandardError => error
        evaluation.update!(status: "failed", last_failure_reason: error.message) if evaluation.persisted?
        failure(error.message)
      end

      private

      attr_reader :evaluation

      def failure(error) = Result.new(success: false, error:, enqueued: false)
    end
  end
end
