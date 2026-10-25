# frozen_string_literal: true

module IntentConformance
  module ShadowEvaluation
    # Authorized cancellation for the asynchronous execution lifecycle
    # (#4642). A queued execution cancels before any reviewer spend; a
    # running one is asked to stop between cases (cooperative flag read at
    # each case boundary by ExecuteReviewer). Cancellation never deletes or
    # fabricates recorded runs — collected evidence is preserved exactly as
    # executed, and unvisited cases simply stay without a verdict.
    # @spec INTENT-CONFORMANCE-ROLLOUT-011
    class CancelExecution
      Result = Data.define(:success, :error, :evaluation, :state) do
        def success? = success
        def cancelled? = state == :cancelled
        def cancelling? = state == :cancelling
      end

      def self.call(...) = new(...).call

      def initialize(evaluation:, actor: nil)
        @evaluation = evaluation
        @actor = actor
      end

      def call
        return failure("execution is not queued or running") unless @evaluation.execution_pending?

        if @evaluation.queued?
          cancel_before_start
        else
          request_stop_between_cases
        end
      end

      private

      attr_reader :evaluation, :actor

      # The job re-checks the status before it starts, so a cancelled
      # enqueue performs no reviewer spend at all.
      def cancel_before_start
        evaluation.update!(
          status: "cancelled",
          cancel_requested_at: Time.current,
          last_failure_reason: "execution cancelled before it started; no reviewer spend for this attempt"
        )
        log_cancelled(:cancelled_before_start)
        Result.new(success: true, error: nil, evaluation: evaluation.reload, state: :cancelled)
      end

      # The running executor honors the flag at the next case boundary and
      # records the terminal cancelled state itself; already-recorded runs
      # are untouched evidence.
      def request_stop_between_cases
        evaluation.update!(cancel_requested_at: Time.current)
        log_cancelled(:stop_requested)
        Result.new(success: true, error: nil, evaluation: evaluation.reload, state: :cancelling)
      end

      def log_cancelled(transition)
        Rails.logger.info(
          message: "intent_conformance.shadow_execution_cancel_#{transition}",
          project_id: evaluation.project_id,
          shadow_evaluation_id: evaluation.id,
          actor_user_id: actor&.id
        )
      end

      def failure(message)
        Result.new(success: false, error: message, evaluation: nil, state: nil)
      end
    end
  end
end
