# frozen_string_literal: true

module Activities
  class CreateAgentRunActivity < BaseActivity
    activity_name "CreateAgentRun"

    def execute(input)
      project_id = input[:project_id]
      issue_id = input[:issue_id]
      agent_type = input.fetch(:agent_type, "claude_code")
      project = Project.find(project_id)
      issue = Issue.find(issue_id)

      agent_run = AgentRun.create!(
        project: project,
        issue: issue,
        agent_type: agent_type,
        status: "pending"
      )

      issue.update!(paid_state: "in_progress")

      logger.info(
        message: "agent_execution.agent_run_created",
        agent_run_id: agent_run.id,
        project_id: project_id,
        issue_id: issue_id
      )

      { agent_run_id: agent_run.id }
    end
  end
end
