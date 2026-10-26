# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Durable admission for reviewer work. The controller and documented task
    # both use this boundary, so neither can bypass the lifecycle or enqueue
    # a duplicate paid reviewer invocation.
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
        error = ExecuteReviewer.preflight(evaluation)
        return failure(error) if error

        enqueued = claim_queue_slot
        ExecuteJob.perform_later(evaluation.id) if enqueued
        Result.new(success: true, error: nil, evaluation:, enqueued:)
      rescue GoodJob::ActiveJobExtensions::Concurrency::ConcurrencyExceededError
        Result.new(success: true, error: nil, evaluation:, enqueued: false)
      end

      private

      attr_reader :evaluation

      def claim_queue_slot
        evaluation.with_lock do
          evaluation.reload
          return false if evaluation.queued?
          return false if evaluation.running? && evaluation.execution_lease_expires_at&.future?
          return false if evaluation.completed? || evaluation.cancelled?

          evaluation.update!(status: "queued", cancel_requested_at: nil, cancelled_at: nil,
            last_failure_reason: nil, execution_lease_expires_at: nil)
          true
        end
      end

      def failure(error)
        Result.new(success: false, error:, evaluation:, enqueued: false)
      end
    end
  end
end
