# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Cooperative cancellation leaves already persisted case evidence intact.
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
        @evaluation.with_lock do
          return failure("reviewer execution is not queued or running") unless @evaluation.executing?

          @evaluation.update!(status: "cancelled", cancel_requested_at: Time.current)
        end
        Result.new(success: true, error: nil)
      end

      private

      def failure(error) = Result.new(success: false, error:)
    end
  end
end
