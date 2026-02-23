# frozen_string_literal: true

module Activities
  class QueueAgentRunActivity < BaseActivity
    activity_name "QueueAgentRun"

    def execute(input)
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
        status: "queued"
      )

      logger.info(
        message: "concurrency.agent_run_queued",
        agent_run_id: agent_run.id,
        project_id: project_id,
        issue_id: issue_id
      )

      { agent_run_id: agent_run.id, queued: true }
    end
  end
end
