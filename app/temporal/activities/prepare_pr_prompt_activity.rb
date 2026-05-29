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
      focus = input[:focus].presence || agent_run.focus.presence || "general"
      project = agent_run.project
      service_environment_prompt_blocks = Prompts::BuildForPr.service_environment_section_render_for(
        project: project,
        include_setup_instruction: false
      ).prompt_blocks

      track_phase(
        agent_run_id: agent_run_id,
        phase_key: "prepare_pr_prompt",
        phase_group: "prompt",
        agent_run: agent_run,
        metadata: { service_environment_prompt_blocks: service_environment_prompt_blocks }
      ) do
        client = project.client
        prompt_version = Prompts::Resolve.call(
          slug: Prompts::BuildForPr::PROMPT_SLUG,
          project: project
        )

        prompt_builder = Prompts::BuildForPr.new(
          project: project,
          pr_number: agent_run.source_pull_request_number,
          github_client: client,
          rebase_succeeded: rebase_succeeded,
          issue: agent_run.issue,
          prompt_version: prompt_version,
          focus: focus
        )
        prompt = prompt_builder.build
        includes_review_threads = prompt_builder.includes_review_threads?
        review_thread_ids = prompt_builder.unresolved_review_thread_ids

        agent_run.update!(custom_prompt: prompt, prompt_version: prompt_version)

        logger.info(
          message: "agent_execution.prepare_pr_prompt",
          agent_run_id: agent_run_id,
          focus: focus,
          prompt_length: prompt.length,
          includes_review_threads: includes_review_threads,
          review_thread_count: review_thread_ids.size,
          prompt_version_id: prompt_version&.id
        )

        {
          agent_run_id: agent_run_id,
          prompt_length: prompt.length,
          includes_review_threads: includes_review_threads,
          review_thread_ids: review_thread_ids,
          prompt_version_id: prompt_version&.id
        }
      end
    end
  end
end
