# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Cancellation is cooperative: a running provider call is allowed to
    # finish, then no subsequent case is spent and recorded evidence survives.
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
        evaluation.with_lock do
          return failure("reviewer execution is not active") unless evaluation.execution_active?

          if evaluation.queued?
            evaluation.update!(status: "cancelled", cancelled_at: Time.current, cancellation_requested_at: Time.current)
          else
            evaluation.update!(cancellation_requested_at: Time.current)
          end
        end
        success
      end

      private

      attr_reader :evaluation

      def success = Result.new(success: true, error: nil, evaluation:)
      def failure(error) = Result.new(success: false, error:, evaluation:)
    end
  end
end
