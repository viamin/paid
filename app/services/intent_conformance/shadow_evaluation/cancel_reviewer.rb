# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Cooperative cancellation intentionally leaves collected runs intact.
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class CancelReviewer
      Result = Data.define(:success, :error, :evaluation) do
        def success? = success
      end

      def self.call(...) = new(...).call

      def initialize(evaluation:)
        @evaluation = evaluation
      end

      def call
        return Result.new(success: false, error: "reviewer execution is not active", evaluation: evaluation) unless evaluation.queued? || evaluation.running?

        evaluation.update!(cancel_requested_at: Time.current)
        evaluation.update!(status: "cancelled", cancelled_at: Time.current) if evaluation.queued?
        Result.new(success: true, error: nil, evaluation: evaluation)
      end

      private

      attr_reader :evaluation
    end
  end
end
