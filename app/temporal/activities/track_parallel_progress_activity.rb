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

      completed = runs.where(status: "completed").count
      failed = runs.where(status: AgentRun::FAILURE_STATUSES).count
      cancelled = runs.where(status: "cancelled").count
      active = runs.where(status: AgentRun::ACTIVE_STATUSES).count
      queued = runs.where(status: "queued").count
      total = agent_run_ids.size

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
        all_finished: all_finished
      )

      {
        total: total,
        completed: completed,
        failed: failed,
        cancelled: cancelled,
        active: active,
        queued: queued,
        all_finished: all_finished
      }
    end
  end
end
