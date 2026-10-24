# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Authorizes exactly one durable worker for an evaluation. A stale
    # heartbeat is deliberately recoverable: advisory locks die with workers,
    # but persisted state must not keep the operator-facing lifecycle stuck.
    # @spec INTENT-CONFORMANCE-ROLLOUT-010
    class ScheduleExecution
      Result = Data.define(:success, :error, :evaluation, :enqueued) do
        def success? = success
        def enqueued? = enqueued
      end

      def self.call(...) = new(...).call

      def initialize(evaluation:)
        @evaluation = evaluation
      end

      def call
        evaluation.with_lock do
          return failure("reviewer execution requires a frozen reference label set") unless evaluation.answers_visible?
          return failure("corpus manifest changed since reference labels were frozen — start a new evaluation") unless evaluation.corpus.matches_recorded_digest?
          return existing unless replaceable?

          evaluation.update!(status: "queued", cancellation_requested_at: nil, execution_heartbeat_at: Time.current,
            execution_attempt: evaluation.execution_attempt + 1)
          IntentConformanceShadowEvaluationExecutionJob.perform_later(evaluation.id, evaluation.execution_attempt)
          Result.new(success: true, error: nil, evaluation: evaluation, enqueued: true)
        end
      end

      private

      attr_reader :evaluation

      def replaceable?
        !evaluation.executing? || evaluation.execution_stale?
      end

      def existing
        Result.new(success: true, error: nil, evaluation: evaluation, enqueued: false)
      end

      def failure(error)
        Result.new(success: false, error: error, evaluation: evaluation, enqueued: false)
      end
    end
  end
end
