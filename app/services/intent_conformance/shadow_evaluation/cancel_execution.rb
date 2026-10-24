# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Cooperative cancellation never interrupts an in-flight provider call;
    # the worker observes it before the next case and leaves durable evidence
    # untouched.
    # @spec INTENT-CONFORMANCE-ROLLOUT-010
    class CancelExecution
      Result = Data.define(:success, :error, :evaluation) do
        def success? = success
      end

      def self.call(...) = new(...).call

      def initialize(evaluation:)
        @evaluation = evaluation
      end

      def call
        evaluation.with_lock do
          return Result.new(success: false, error: "reviewer execution is not active", evaluation: evaluation) unless evaluation.queued? || evaluation.running?

          attributes = { cancellation_requested_at: Time.current }
          attributes[:status] = "cancelled" if evaluation.queued?
          evaluation.update!(attributes)
          Result.new(success: true, error: nil, evaluation: evaluation)
        end
      end

      private

      attr_reader :evaluation
    end
  end
end
