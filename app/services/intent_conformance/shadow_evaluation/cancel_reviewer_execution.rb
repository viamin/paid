# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Cooperative cancellation: evidence already collected is deliberately
    # retained and the executor observes the durable request between cases.
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class CancelReviewerExecution
      Result = Data.define(:success, :error) do
        def success? = success
      end

      def self.call(...) = new(...).call

      def initialize(evaluation:)
        @evaluation = evaluation
      end

      def call
        evaluation.with_lock do
          return Result.new(success: false, error: "reviewer execution is not active") unless evaluation.queued? || evaluation.running?

          evaluation.update!(cancel_requested_at: Time.current)
          evaluation.update!(status: "cancelled", cancelled_at: Time.current) if evaluation.queued?
        end
        Result.new(success: true, error: nil)
      end

      private

      attr_reader :evaluation
    end
  end
end
