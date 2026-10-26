# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Records a cooperative stop request; the worker observes it between cases.
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class CancelExecution
      def self.call(...) = new(...).call

      def initialize(evaluation:)
        @evaluation = evaluation
      end

      def call
        evaluation.with_lock do
          next false unless evaluation.queued? || evaluation.running?

          if evaluation.queued?
            evaluation.update!(status: "cancelled", cancellation_requested_at: Time.current)
          else
            evaluation.update!(cancellation_requested_at: Time.current)
          end
          true
        end
      end

      private

      attr_reader :evaluation
    end
  end
end
