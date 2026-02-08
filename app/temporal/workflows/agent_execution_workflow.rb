# frozen_string_literal: true

module Workflows
  # Placeholder for the agent execution workflow.
  #
  # Will be fully implemented in a separate issue. For now, this exists so that
  # GitHubPollWorkflow can reference it when starting child workflows.
  class AgentExecutionWorkflow < BaseWorkflow
    def execute(project_id:, issue_id:)
      Temporalio::Workflow.logger.info(
        "AgentExecutionWorkflow started for project=#{project_id} issue=#{issue_id} (placeholder)"
      )
    end
  end
end
