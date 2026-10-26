# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Authorized cooperative cancellation of reviewer execution (#4642): the
    # action only records the request. The worker honors it before the first
    # reviewer invocation or between cases, so collected evidence survives,
    # and cases never reached stay without a run row — an unevaluated case is
    # never fabricated as a result. If the worker already died, the recovery
    # sweep re-enqueues the job and the cancellation is honored on resume.
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class CancelExecution
      Result = Data.define(:success, :error, :evaluation) do
        def success? = success
      end

      def self.call(...) = new(...).call

      def initialize(evaluation:, actor: nil)
        @evaluation = evaluation
        @actor = actor
      end

      def call
        return failure("no reviewer execution is queued or running for this evaluation") unless @evaluation.execution_active?

        @evaluation.update!(cancel_requested_at: Time.current)
        log_cancel_requested
        Result.new(success: true, error: nil, evaluation: @evaluation)
      end

      private

      attr_reader :evaluation, :actor

      def log_cancel_requested
        Rails.logger.info(
          message: "intent_conformance.shadow_evaluation_execution_cancel_requested",
          project_id: @evaluation.project_id,
          shadow_evaluation_id: @evaluation.id,
          actor_user_id: @actor&.id
        )
      end

      def failure(message)
        Result.new(success: false, error: message, evaluation: nil)
      end
    end
  end
end
