# frozen_string_literal: true

module Activities
  class CreateAgentRunActivity < BaseActivity
    activity_name "CreateAgentRun"

    def execute(project_id:, issue_id:, agent_type:, temporal_workflow_id: nil, temporal_run_id: nil)
      project = Project.find(project_id)
      issue = Issue.find(issue_id)

      agent_run = AgentRun.create!(
        project: project,
        issue: issue,
        agent_type: agent_type,
        status: "pending",
        temporal_workflow_id: temporal_workflow_id,
        temporal_run_id: temporal_run_id
      )

      issue.update!(paid_state: "in_progress")

      if temporal_workflow_id
        update_workflow_state(temporal_workflow_id, {
          workflow_type: "AgentExecution",
          project_id: project_id,
          status: "running",
          started_at: Time.current,
          input_data: { issue_id: issue_id, agent_type: agent_type }
        })
      end

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
