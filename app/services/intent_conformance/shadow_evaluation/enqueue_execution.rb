# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Records a durable, idempotent request before dispatching the worker. The
    # recovery sweep re-enqueues queued rows if a process dies between these
    # two operations.
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
        enqueued = @evaluation.with_lock do
          return failure("reviewer execution requires a frozen reference label set") unless @evaluation.answers_visible?
          return failure("corpus manifest changed since reference labels were frozen — start a new evaluation") unless @evaluation.corpus.matches_recorded_digest?
          return Result.new(success: true, error: nil, enqueued: false) if @evaluation.queued? || @evaluation.running? || @evaluation.completed?

          @evaluation.update!(status: "queued", execution_enqueued_at: Time.current, cancellation_requested_at: nil,
            last_failure_reason: nil)
          true
        end
        ShadowEvaluationExecutionJob.perform_later(@evaluation.id) if enqueued
        Result.new(success: true, error: nil, enqueued: enqueued)
      end

      private

      def failure(error) = Result.new(success: false, error:, enqueued: false)
    end
  end
end
