# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Cooperative cancellation deliberately does not delete rows: a completed
    # case is evidence and a later resume spends only on unfinished cases.
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class RequestCancellation
      Result = Data.define(:success, :error) do
        def success? = success
      end

      def self.call(...) = new(...).call

      def initialize(evaluation:)
        @evaluation = evaluation
      end

      def call
        @evaluation.with_lock do
          return failure("reviewer execution is not active") unless @evaluation.queued? || @evaluation.running?

          if @evaluation.queued?
            @evaluation.update!(status: "cancelled", cancellation_requested_at: Time.current,
              last_failure_reason: "cancelled by an authorized operator")
          else
            @evaluation.update!(cancellation_requested_at: Time.current)
          end
        end
        Result.new(success: true, error: nil)
      end

      private

      def failure(error) = Result.new(success: false, error:)
    end
  end
end
