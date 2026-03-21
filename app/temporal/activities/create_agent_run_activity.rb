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
      goal = input.fetch(:goal, "create_pr")
      source_pull_request_number = input[:source_pull_request_number]

      project = Project.find(project_id)
      issue = issue_id ? Issue.find(issue_id) : nil
      user_settings = resolve_user_settings(project)

      # Resolve and render prompt version if no custom prompt is provided.
      # Skip for untrusted issues to match the safety behavior in AgentRun#prompt_for_issue.
      prompt_version = nil
      if custom_prompt.blank? && issue.present? && issue.trusted?
        prompt_version = Prompts::Resolve.call(slug: "coding.issue_implementation", project: project)
        if prompt_version
          custom_prompt = prompt_version.render(
            title: issue.title,
            issue_number: issue.github_number.to_s,
            body: issue.body.to_s,
            test_command: test_command_for(project),
            lint_command: lint_command_for(project)
          )
          # Append trusted issue comments so they reach the agent even when
          # the rendered PromptVersion is stored as custom_prompt (which
          # bypasses BuildForIssue in effective_prompt).
          custom_prompt += Prompts::BuildForIssue.conversation_section_for(
            project: project, issue: issue,
            github_client: project.github_token&.client
          )
        end
      end

      agent_run = AgentRun.create!(
        project: project,
        issue: issue,
        agent_type: agent_type,
        goal: goal,
        custom_prompt: custom_prompt,
        source_pull_request_number: source_pull_request_number,
        prompt_version: prompt_version,
        status: "pending"
      )

      track_phase(
        agent_run_id: agent_run.id,
        agent_run: agent_run,
        phase_key: "create_agent_run",
        phase_group: "prompt",
        metadata: {
          prompt_version_id: prompt_version&.id,
          custom_prompt_provided: input[:custom_prompt].present?
        },
        started_at: agent_run.created_at
      ) do
        issue&.update!(paid_state: "in_progress")

        # Select model for this run (creates a ModelSelection record for cost
        # tracking and audit). Non-fatal — runs proceed with default pricing
        # if no LlmModel records exist yet.
        select_model(agent_run)

        logger.info(
          message: "agent_execution.agent_run_created",
          agent_run_id: agent_run.id,
          project_id: project_id,
          issue_id: issue_id,
          custom_prompt_provided: input[:custom_prompt].present?,
          prompt_version_id: prompt_version&.id
        )

        {
          agent_run_id: agent_run.id,
          provider_attempt_count: provider_attempt_count_for(agent_type, user_settings)
        }
      end
    end

    private

    def resume_queued_run(agent_run_id)
      agent_run = AgentRun.find(agent_run_id)

      if agent_run.queued?
        agent_run.update!(status: "pending")
      elsif agent_run.status != "pending"
        # "pending" is expected — ProcessRunQueueJob claims runs (queued→pending)
        # before starting the workflow. Only warn for truly unexpected statuses.
        logger.warn(
          message: "agent_execution.resume_queued_run_unexpected_status",
          agent_run_id: agent_run.id,
          current_status: agent_run.status,
          project_id: agent_run.project_id
        )
      end

      agent_run.issue&.update!(paid_state: "in_progress")
      select_model(agent_run) unless agent_run.model_selection

      logger.info(
        message: "agent_execution.queued_run_resumed",
        agent_run_id: agent_run.id,
        project_id: agent_run.project_id,
        issue_id: agent_run.issue_id
      )

      {
        agent_run_id: agent_run.id,
        provider_attempt_count: provider_attempt_count_for(agent_run.agent_type, resolve_user_settings(agent_run.project))
      }
    end

    def select_model(agent_run)
      Models::Select.call(agent_run: agent_run)
    rescue => e
      logger.warn(
        message: "agent_execution.model_selection_failed",
        agent_run_id: agent_run.id,
        error_class: e.class.name,
        error: e.message,
        backtrace: e.backtrace&.first(5)
      )
    end

    def resolve_user_settings(project)
      AgentRuns::UserSettingsResolver.call(project: project, strict: false)
    end

    def provider_attempt_count_for(agent_type, user_settings)
      return 1 unless user_settings

      primary_provider = Activities::RunAgentActivity::AGENT_TYPE_TO_PROVIDER.fetch(agent_type, agent_type)

      count = Activities::RunAgentActivity.provider_attempt_count(
        agent_type: agent_type,
        fallback_enabled: user_settings.fallback_enabled,
        fallback_providers: user_settings.fallback_priority_for(primary_provider: primary_provider)
      )

      [ count, 1 ].max
    end

    def test_command_for(project)
      Prompts::LanguageCommands::LANGUAGE_TEST_COMMANDS.fetch(
        Prompts::LanguageCommands.detected_language(project),
        "echo \"No test command configured\""
      )
    end

    def lint_command_for(project)
      Prompts::LanguageCommands::LANGUAGE_LINT_COMMANDS.fetch(
        Prompts::LanguageCommands.detected_language(project),
        "echo \"No lint command configured\""
      )
    end
  end
end
