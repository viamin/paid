# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Cancellation is cooperative: a provider call already in progress may
    # finish and be recorded, but no subsequent case is started.
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class CancelReviewer
      Result = Data.define(:success, :error) do
        def success? = success
      end

      def self.call(...) = new(...).call

      def initialize(evaluation:)
        @evaluation = evaluation
      end

      def call
        return failure("reviewer execution is not queued or running") unless evaluation.executing?

        evaluation.with_lock do
          evaluation.update!(status: "cancelled", cancellation_requested_at: Time.current, cancelled_at: Time.current)
        end
        Result.new(success: true, error: nil)
      end

      private

      attr_reader :evaluation
      def failure(error) = Result.new(success: false, error:)
    end
  end
end
