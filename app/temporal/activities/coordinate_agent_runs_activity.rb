# frozen_string_literal: true

module Activities
  # Temporal activity that coordinates related agent runs within a parallel
  # execution workflow. Provides three operations:
  #
  # 1. **check_dependencies** - Determines whether a run's dependencies are met
  # 2. **notify_completion** - Broadcasts completion signals (files changed, context)
  # 3. **propagate_failure** - Broadcasts failure and optionally cancels dependents
  #
  # Input:
  #   operation: "check_dependencies" | "notify_completion" | "propagate_failure"
  #   agent_run_id: ID of the agent run
  #   required_run_ids: (check_dependencies) IDs of runs that must complete first
  #   changed_files: (notify_completion) Files modified by the completed run
  #   context: (notify_completion) Arbitrary context to share with siblings
  #   cancel_dependents: (propagate_failure) Whether to cancel queued dependents
  #   dependent_run_ids: (propagate_failure) Specific runs to cancel
  class CoordinateAgentRunsActivity < BaseActivity
    activity_name "CoordinateAgentRuns"

    OPERATIONS = %w[check_dependencies notify_completion propagate_failure].freeze

    def execute(input)
      operation = input[:operation]

      unless OPERATIONS.include?(operation)
        raise Temporalio::Error::ApplicationError.new(
          "Unknown coordination operation: #{operation}",
          type: "InvalidInput",
          non_retryable: true
        )
      end

      send(:"execute_#{operation}", input)
    end

    private

    def execute_check_dependencies(input)
      agent_run = AgentRun.find(input[:agent_run_id])
      required_run_ids = Array(input[:required_run_ids])

      result = Coordination::ResolveDependencies.call(
        agent_run: agent_run,
        required_run_ids: required_run_ids
      )

      logger.info(
        message: "coordination.check_dependencies",
        agent_run_id: agent_run.id,
        ready: result.ready?,
        failed: result.failed?,
        required_run_ids: required_run_ids
      )

      {
        ready: result.ready?,
        failed: result.failed?,
        failed_run_ids: result.failed_run_ids,
        error: result.error
      }
    end

    def execute_notify_completion(input)
      agent_run = AgentRun.find(input[:agent_run_id])
      changed_files = Array(input[:changed_files])
      context = input[:context] || {}

      signals_sent = []

      if changed_files.any?
        result = Coordination::SendSignal.call(
          source_agent_run: agent_run,
          signal_type: "files_changed",
          payload: { files: changed_files }
        )
        signals_sent << "files_changed" if result.success?
      end

      result = Coordination::SendSignal.call(
        source_agent_run: agent_run,
        signal_type: "dependency_completed",
        payload: {
          completed_at: agent_run.completed_at&.iso8601,
          branch_name: agent_run.branch_name,
          result_commit_sha: agent_run.result_commit_sha
        }.merge(context)
      )
      signals_sent << "dependency_completed" if result.success?

      if context.any?
        result = Coordination::SendSignal.call(
          source_agent_run: agent_run,
          signal_type: "context_shared",
          payload: context
        )
        signals_sent << "context_shared" if result.success?
      end

      logger.info(
        message: "coordination.notify_completion",
        agent_run_id: agent_run.id,
        signals_sent: signals_sent,
        changed_files_count: changed_files.size
      )

      { success: true, signals_sent: signals_sent }
    end

    def execute_propagate_failure(input)
      agent_run = AgentRun.find(input[:agent_run_id])
      cancel_dependents = input.fetch(:cancel_dependents, false)
      dependent_run_ids = Array(input[:dependent_run_ids])

      result = Coordination::PropagateFailure.call(
        failed_agent_run: agent_run,
        dependent_run_ids: dependent_run_ids,
        cancel_dependents: cancel_dependents
      )

      logger.info(
        message: "coordination.propagate_failure",
        agent_run_id: agent_run.id,
        success: result.success?,
        cancelled_run_ids: result.cancelled_run_ids
      )

      {
        success: result.success?,
        cancelled_run_ids: result.cancelled_run_ids,
        error: result.error
      }
    end
  end
end
