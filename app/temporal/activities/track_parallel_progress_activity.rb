# frozen_string_literal: true

module Activities
  # Tracks the progress of parallel child workflow executions by querying
  # the status of their associated agent runs. Returns aggregate completion
  # status so the parent workflow can monitor progress.
  class TrackParallelProgressActivity < BaseActivity
    activity_name "TrackParallelProgress"

    def execute(input)
      parent_workflow_id = input[:parent_workflow_id]
      agent_run_ids = input[:agent_run_ids] || []

      runs = AgentRun.where(id: agent_run_ids)
      counts_by_status = runs.group(:status).count

      completed = counts_by_status["completed"].to_i
      failed = AgentRun::FAILURE_STATUSES.sum { |status| counts_by_status[status].to_i }
      cancelled = counts_by_status["cancelled"].to_i
      active = AgentRun::ACTIVE_STATUSES.sum { |status| counts_by_status[status].to_i }
      queued = counts_by_status["queued"].to_i

      # Use the count of actually-found runs as total so missing IDs
      # (deleted or invalid) don't prevent all_finished from becoming true.
      found_count = counts_by_status.values.sum
      missing = agent_run_ids.size - found_count
      total = found_count

      all_finished = (completed + failed + cancelled) == total && total > 0

      logger.info(
        message: "parallel_execution.progress",
        parent_workflow_id: parent_workflow_id,
        total: total,
        completed: completed,
        failed: failed,
        cancelled: cancelled,
        active: active,
        queued: queued,
        missing: missing,
        all_finished: all_finished
      )

      {
        total: total,
        completed: completed,
        failed: failed,
        cancelled: cancelled,
        active: active,
        queued: queued,
        missing: missing,
        all_finished: all_finished
      }
    end
  end
end
