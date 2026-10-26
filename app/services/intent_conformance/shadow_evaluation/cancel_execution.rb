# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Cancellation is cooperative: a current provider request is allowed to
    # return, then the worker stops before the next case and retains its run.
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
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
          return failure("reviewer execution is not queued or running") unless evaluation.queued? || evaluation.running?

          attributes = { execution_cancel_requested: true }
          attributes[:status] = "cancelled" if evaluation.queued?
          evaluation.update!(attributes)
        end
        Result.new(success: true, error: nil, evaluation:)
      end

      private

      attr_reader :evaluation

      def failure(error) = Result.new(success: false, error:, evaluation:)
    end
  end
end
