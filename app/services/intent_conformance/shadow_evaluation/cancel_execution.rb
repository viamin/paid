# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Cooperative cancellation: an in-flight provider request may finish, but
    # no further corpus case can begin after the durable cancellation marker.
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class CancelExecution
      Result = Data.define(:success, :error) do
        def success? = success
      end

      def self.call(...) = new(...).call

      def initialize(evaluation:)
        @evaluation = evaluation
      end

      def call
        return Result.new(success: false, error: "reviewer execution is not queued or running") unless evaluation.executing?

        attributes = { execution_cancelled_at: Time.current }
        attributes[:status] = "cancelled" if evaluation.queued?
        evaluation.update!(attributes)
        Result.new(success: true, error: nil)
      end

      private

      attr_reader :evaluation
    end
  end
end
