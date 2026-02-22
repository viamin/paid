# frozen_string_literal: true

module Activities
  # Builds a rich prompt for an existing PR run and stores it in custom_prompt.
  #
  # Gathers CI failures, review threads, conversation comments, and optionally
  # linked issue requirements. The generated prompt is written to custom_prompt
  # so that RunAgentActivity picks it up via effective_prompt without changes.
  class PreparePrPromptActivity < BaseActivity
    activity_name "PreparePrPrompt"

    def execute(input)
      agent_run_id = input[:agent_run_id]
      rebase_succeeded = input.fetch(:rebase_succeeded, true)
      agent_run = AgentRun.find(agent_run_id)
      project = agent_run.project
      client = project.github_token.client

      prompt = Prompts::BuildForPr.call(
        project: project,
        pr_number: agent_run.source_pull_request_number,
        github_client: client,
        rebase_succeeded: rebase_succeeded,
        issue: agent_run.issue
      )

      agent_run.update!(custom_prompt: prompt)

      logger.info(
        message: "agent_execution.prepare_pr_prompt",
        agent_run_id: agent_run_id,
        prompt_length: prompt.length
      )

      { agent_run_id: agent_run_id, prompt_length: prompt.length }
    end
  end
end
