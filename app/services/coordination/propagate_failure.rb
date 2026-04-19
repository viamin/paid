# frozen_string_literal: true

module Coordination
  # When an agent run fails, broadcasts a `dependency_failed` signal so that
  # dependent runs in the same workflow can react (skip, cancel, or re-plan).
  #
  # Optionally cancels dependent runs that are still queued or pending.
  #
  # @example
  #   Coordination::PropagateFailure.call(
  #     failed_agent_run: run,
  #     cancel_dependents: true
  #   )
  class PropagateFailure
    def self.call(...)
      new(...).call
    end

    def initialize(failed_agent_run:, dependent_run_ids: [], cancel_dependents: false)
      @failed_agent_run = failed_agent_run
      @dependent_run_ids = Array(dependent_run_ids).map(&:to_i)
      @cancel_dependents = cancel_dependents
    end

    def call
      unless failed_agent_run.parent_workflow_id.present?
        return Result.new(success: false, error: "failed run has no parent_workflow_id")
      end

      signal_result = Coordination::SendSignal.call(
        source_agent_run: failed_agent_run,
        signal_type: "dependency_failed",
        payload: {
          error_message: failed_agent_run.error_message.to_s.truncate(1000),
          failed_status: failed_agent_run.status
        }
      )

      return Result.new(success: false, error: signal_result.error) unless signal_result.success?

      cancelled_ids = cancel_dependent_runs if cancel_dependents

      Rails.logger.info(
        message: "coordination.failure_propagated",
        failed_agent_run_id: failed_agent_run.id,
        parent_workflow_id: failed_agent_run.parent_workflow_id,
        cancelled_run_ids: cancelled_ids || []
      )

      Result.new(success: true, signal: signal_result.signal, cancelled_run_ids: cancelled_ids || [])
    end

    private

    attr_reader :failed_agent_run, :dependent_run_ids, :cancel_dependents

    def cancel_dependent_runs
      scope = AgentRun.where(parent_workflow_id: failed_agent_run.parent_workflow_id)
        .where(status: AgentRun::UNFINISHED_STATUSES)

      scope = scope.where(id: dependent_run_ids) if dependent_run_ids.any?

      # Exclude the failed run itself
      scope = scope.where.not(id: failed_agent_run.id)

      cancelled = []
      scope.find_each do |run|
        run.cancel!
        cancelled << run.id
      rescue => e
        Rails.logger.warn(
          message: "coordination.cancel_dependent_failed",
          agent_run_id: run.id,
          error: e.message
        )
      end

      cancelled
    end

    class Result
      attr_reader :signal, :error, :cancelled_run_ids

      def initialize(success:, signal: nil, error: nil, cancelled_run_ids: [])
        @success = success
        @signal = signal
        @error = error
        @cancelled_run_ids = cancelled_run_ids
      end

      def success? = @success
    end
  end
end
