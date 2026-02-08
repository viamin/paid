# frozen_string_literal: true

# Manages Temporal workflow lifecycle for projects.
#
# Starts and stops the GitHubPollWorkflow that monitors repositories
# for labeled issues.
class ProjectWorkflowManager
  class << self
    def start_polling(project)
      Paid.temporal_client.start_workflow(
        Workflows::GitHubPollWorkflow,
        { project_id: project.id },
        id: workflow_id_for(project),
        task_queue: Paid.task_queue
      )

      Rails.logger.info(
        message: "github_sync.polling_started",
        project_id: project.id,
        workflow_id: workflow_id_for(project)
      )
    rescue Temporalio::Error::WorkflowAlreadyStartedError
      Rails.logger.warn(
        message: "github_sync.polling_already_running",
        project_id: project.id
      )
    end

    def stop_polling(project)
      handle = Paid.temporal_client.workflow_handle(workflow_id_for(project))
      handle.cancel

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

    private

    def workflow_id_for(project)
      "github-poll-#{project.id}"
    end
  end
end
