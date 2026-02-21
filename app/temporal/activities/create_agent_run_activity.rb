# frozen_string_literal: true

module Activities
  class CreateAgentRunActivity < BaseActivity
    activity_name "CreateAgentRun"

    def execute(input)
      project_id = input[:project_id]
      issue_id = input[:issue_id]
      custom_prompt = input[:custom_prompt]
      agent_type = input.fetch(:agent_type, "claude_code")
      source_pull_request_number = input[:source_pull_request_number]

      project = Project.find(project_id)
      issue = issue_id ? Issue.find(issue_id) : nil

      # Resolve prompt version if no custom prompt is provided
      prompt_version = nil
      if custom_prompt.blank? && issue.present?
        prompt_version = Prompts::Resolve.call(slug: "coding.issue_implementation", project: project)
      end

      agent_run = AgentRun.create!(
        project: project,
        issue: issue,
        agent_type: agent_type,
        custom_prompt: custom_prompt,
        source_pull_request_number: source_pull_request_number,
        prompt_version: prompt_version,
        status: "pending"
      )

      issue&.update!(paid_state: "in_progress")

      logger.info(
        message: "agent_execution.agent_run_created",
        agent_run_id: agent_run.id,
        project_id: project_id,
        issue_id: issue_id,
        has_custom_prompt: custom_prompt.present?,
        prompt_version_id: prompt_version&.id
      )

      { agent_run_id: agent_run.id }
    end
  end
end
