# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Authorizes the durable operation only. Provider work belongs to ExecuteJob.
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class RequestExecution
      Result = Data.define(:success, :error, :queued) do
        def success? = success
      end

      def self.call(...) = new(...).call

      def initialize(evaluation:)
        @evaluation = evaluation
      end

      def call
        @evaluation.with_lock do
          return Result.new(success: true, error: nil, queued: false) if @evaluation.executing?
          return failure("reviewer execution requires a frozen reference label set") unless @evaluation.answers_visible?
          return failure("corpus manifest changed since reference labels were frozen — start a new evaluation") unless @evaluation.corpus.matches_recorded_digest?

          @evaluation.update!(status: "queued", cancel_requested_at: nil, last_failure_reason: nil)
          ExecuteJob.perform_later(@evaluation.id)
          Result.new(success: true, error: nil, queued: true)
        end
      end

      private

      def failure(error) = Result.new(success: false, error:, queued: false)
    end
  end
end
