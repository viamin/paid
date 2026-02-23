# frozen_string_literal: true

module Activities
  class CreateAgentRunActivity < BaseActivity
    activity_name "CreateAgentRun"

    def execute(input)
      agent_run_id = input[:agent_run_id]

      if agent_run_id
        return resume_queued_run(agent_run_id)
      end

      project_id = input[:project_id]
      issue_id = input[:issue_id]
      custom_prompt = input[:custom_prompt]
      agent_type = input.fetch(:agent_type, "claude_code")
      source_pull_request_number = input[:source_pull_request_number]

      project = Project.find(project_id)
      issue = issue_id ? Issue.find(issue_id) : nil

      agent_run = AgentRun.create!(
        project: project,
        issue: issue,
        agent_type: agent_type,
        custom_prompt: custom_prompt,
        source_pull_request_number: source_pull_request_number,
        status: "pending"
      )

      issue&.update!(paid_state: "in_progress")

      logger.info(
        message: "agent_execution.agent_run_created",
        agent_run_id: agent_run.id,
        project_id: project_id,
        issue_id: issue_id,
        has_custom_prompt: custom_prompt.present?
      )

      { agent_run_id: agent_run.id }
    end

    private

    def resume_queued_run(agent_run_id)
      agent_run = AgentRun.find(agent_run_id)
      agent_run.update!(status: "pending") if agent_run.queued?
      agent_run.issue&.update!(paid_state: "in_progress")

      logger.info(
        message: "agent_execution.queued_run_resumed",
        agent_run_id: agent_run.id,
        project_id: agent_run.project_id,
        issue_id: agent_run.issue_id
      )

      { agent_run_id: agent_run.id }
    end
  end
end
