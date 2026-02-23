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
    Project.where("poll_interval_seconds > 0").find_each do |project|
      check_and_heal(project)
    rescue => e
      Rails.logger.error(
        message: "temporal_worker.health_check_failed",
        project_id: project.id,
        error: e.message
      )
    end
  end

  private

  RESTARTABLE_STATUSES = [
    Temporalio::Client::WorkflowExecutionStatus::FAILED,
    Temporalio::Client::WorkflowExecutionStatus::TERMINATED,
    Temporalio::Client::WorkflowExecutionStatus::TIMED_OUT,
    :not_found
  ].freeze

  def check_and_heal(project)
    status = ProjectWorkflowManager.workflow_status(project)
    return if status[:running]
    return unless RESTARTABLE_STATUSES.include?(status[:status])

    # Re-check to reduce race conditions with other lifecycle operations
    latest_status = ProjectWorkflowManager.workflow_status(project)
    return if latest_status[:running]

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
  end
end
