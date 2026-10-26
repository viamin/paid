# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Cooperative cancellation: a provider call already in flight is allowed
    # to finish, but no later corpus case can spend after this durable signal.
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
        return Result.new(success: false, error: "reviewer execution is not active") unless active?

        evaluation.with_lock do
          evaluation.update!(status: "cancelled", cancel_requested_at: Time.current, cancelled_at: Time.current)
        end
        Result.new(success: true, error: nil)
      end

      private

      attr_reader :evaluation

      def active? = evaluation.queued? || evaluation.executing?
    end
  end
end
