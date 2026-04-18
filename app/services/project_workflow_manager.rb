# frozen_string_literal: true

# Manages Temporal workflow lifecycle for projects.
#
# Starts and stops the GitHubPollWorkflow that monitors repositories
# for labeled issues.
class ProjectWorkflowManager
  class << self
    def start_polling(project, restart_reason: nil, raise_on_conflict: false)
      Paid.temporal_client.start_workflow(
        Workflows::GitHubPollWorkflow,
        { project_id: project.id },
        id: workflow_id_for(project),
        task_queue: Paid.poll_task_queue
      )

      WorkflowState.record_polling_status(
        project,
        status: "running",
        restart_reason: restart_reason
      )

      Rails.logger.info(
        message: "github_sync.polling_started",
        project_id: project.id,
        workflow_id: workflow_id_for(project)
      )
      true
    rescue Temporalio::Error::WorkflowAlreadyStartedError
      raise if raise_on_conflict

      Rails.logger.warn(
        message: "github_sync.polling_already_running",
        project_id: project.id
      )
      false
    end

    def stop_polling(project)
      handle = Paid.temporal_client.workflow_handle(workflow_id_for(project))
      handle.cancel

      WorkflowState.record_polling_status(project, status: "cancelled")

      Rails.logger.info(
        message: "github_sync.polling_stopped",
        project_id: project.id
      )
    rescue Temporalio::Error::RPCError => e
      raise unless e.code == Temporalio::Error::RPCError::Code::NOT_FOUND

      Rails.logger.info(
        message: "github_sync.polling_not_running",
        project_id: project.id
      )
    end

    def workflow_status(project)
      handle = Paid.temporal_client.workflow_handle(workflow_id_for(project))
      desc = handle.describe
      {
        status: desc.status,
        running: desc.status == Temporalio::Client::WorkflowExecutionStatus::RUNNING
      }
    rescue Temporalio::Error::RPCError => e
      raise unless e.code == Temporalio::Error::RPCError::Code::NOT_FOUND
      { status: :not_found, running: false }
    end

    def restart_polling(project, reason: nil)
      begin
        handle = Paid.temporal_client.workflow_handle(workflow_id_for(project))
        handle.terminate(reason || "self-healing restart")
      rescue Temporalio::Error::RPCError => e
        raise unless e.code == Temporalio::Error::RPCError::Code::NOT_FOUND
      end

      start_polling(
        project,
        restart_reason: reason || "self-healing restart",
        raise_on_conflict: true
      )
    end

    def signal_sync(project)
      handle = Paid.temporal_client.workflow_handle(workflow_id_for(project))
      handle.signal("request_sync")
    rescue Temporalio::Error::RPCError => e
      raise unless e.code == Temporalio::Error::RPCError::Code::NOT_FOUND
      Rails.logger.warn(
        message: "github_sync.signal_sync_workflow_not_found",
        project_id: project.id
      )
    end

    def restart_all_polling(reason: "deployment")
      Project.active.where("poll_interval_seconds > 0").find_each do |project|
        restart_polling(project, reason: reason)
      rescue => e
        Rails.logger.error(
          message: "github_sync.restart_failed",
          project_id: project.id,
          error: e.message
        )
      end
    end

    private

    def workflow_id_for(project)
      "github-poll-#{project.id}"
    end
  end
end
