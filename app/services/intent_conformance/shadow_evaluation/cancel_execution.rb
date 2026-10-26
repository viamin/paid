# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Cooperative cancellation deliberately preserves already-recorded case
    # evidence. A running reviewer sees this durable flag before the next case.
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class CancelExecution
      Result = Data.define(:success, :error, :evaluation, :cancelled) do
        def success? = success
      end

      def self.call(...) = new(...).call

      def initialize(evaluation:)
        @evaluation = evaluation
      end

      def call
        evaluation.with_lock do
          return failure("reviewer execution is not active") unless evaluation.queued? || evaluation.running?

          if evaluation.queued?
            evaluation.update!(status: "cancelled", cancelled_at: Time.current, execution_lease_expires_at: nil)
          else
            evaluation.update!(cancel_requested_at: Time.current)
          end
        end
        Result.new(success: true, error: nil, evaluation:, cancelled: true)
      end

      private

      attr_reader :evaluation

      def failure(error) = Result.new(success: false, error:, evaluation:, cancelled: false)
    end
  end
end
