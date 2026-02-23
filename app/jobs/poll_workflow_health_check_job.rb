# frozen_string_literal: true

# Monitors Temporal poll workflows and restarts any that are not running.
#
# Catches failures caused by:
# - Nondeterminism errors after deploys
# - Uncaught bugs in workflow code
# - Crashed workers or connection issues
#
# Scheduled via GoodJob cron every 5 minutes.
class PollWorkflowHealthCheckJob < ApplicationJob
  queue_as :maintenance

  def perform
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    checked = 0
    restarted = 0

    Project.active.where("poll_interval_seconds > 0").find_each do |project|
      checked += 1
      restarted += 1 if check_and_heal(project)
    rescue => e
      Rails.logger.error(
        message: "temporal_worker.health_check_failed",
        project_id: project.id,
        error: e.message
      )
    end

    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
    Rails.logger.info(
      message: "temporal_worker.health_check_completed",
      projects_checked: checked,
      projects_restarted: restarted,
      duration_ms: duration_ms
    )
  end

  private

  RESTARTABLE_STATUSES = [
    Temporalio::Client::WorkflowExecutionStatus::FAILED,
    Temporalio::Client::WorkflowExecutionStatus::TERMINATED,
    Temporalio::Client::WorkflowExecutionStatus::TIMED_OUT,
    Temporalio::Client::WorkflowExecutionStatus::COMPLETED,
    :not_found
  ].freeze

  def check_and_heal(project)
    status = ProjectWorkflowManager.workflow_status(project)
    return if status[:running]
    return unless RESTARTABLE_STATUSES.include?(status[:status])

    # Re-check to reduce race conditions with other lifecycle operations
    latest_status = ProjectWorkflowManager.workflow_status(project)
    return if latest_status[:running]
    return unless RESTARTABLE_STATUSES.include?(latest_status[:status])

    Rails.logger.warn(
      message: "temporal_worker.poll_workflow_not_running",
      project_id: project.id,
      workflow_status: latest_status[:status]
    )

    ProjectWorkflowManager.restart_polling(project, reason: "health check: was #{latest_status[:status]}")

    Rails.logger.info(
      message: "temporal_worker.poll_workflow_restarted",
      project_id: project.id
    )
    true
  end
end
