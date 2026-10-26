# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Claims an evaluation execution before enqueueing its idempotent worker.
    # The row lock makes repeated UI/API/CLI submissions harmless while the
    # worker's advisory lock continues to protect actual reviewer spend.
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class EnqueueExecution
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
          return success(false) if evaluation.queued? || evaluation.running?

          evaluation.update!(
            status: "queued",
            execution_cancel_requested: false,
            execution_enqueued_at: Time.current,
            execution_heartbeat_at: nil,
            last_failure_reason: nil
          )
        end
        ExecuteJob.perform_later(evaluation.project_id, evaluation.id)
        success(true)
      end

      private

      attr_reader :evaluation

      def success(enqueued) = Result.new(success: true, error: nil, evaluation:, enqueued:)
      def failure(error) = Result.new(success: false, error:, evaluation:, enqueued: false)
    end
  end
end
