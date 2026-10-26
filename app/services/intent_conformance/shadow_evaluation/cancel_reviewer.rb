# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # @spec INTENT-CONFORMANCE-ROLLOUT-007 @spec INTENT-CONFORMANCE-ROLLOUT-009
    class CancelReviewer
      Result = Data.define(:success, :error) do
        def success? = success
      end

      def self.call(...) = new(...).call

      def initialize(evaluation:) = @evaluation = evaluation

      def call
        evaluation.with_lock do
          return Result.new(success: false, error: "reviewer execution is not queued or running") unless evaluation.queued? || evaluation.running?

          evaluation.update!(cancel_requested_at: Time.current)
          evaluation.update!(status: "cancelled") if evaluation.queued?
        end
        Result.new(success: true, error: nil)
      end

      private

      attr_reader :evaluation
    end
  end
end
