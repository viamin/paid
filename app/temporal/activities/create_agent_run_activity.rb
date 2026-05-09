# frozen_string_literal: true

module Activities
  class CreateAgentRunActivity < BaseActivity
    activity_name "CreateAgentRun"

    NON_CONTAINER_GOALS = %w[enhance_issue analyze_issue].freeze

    def execute(input)
      agent_run_id = input[:agent_run_id]

      if agent_run_id
        return resume_queued_run(agent_run_id)
      end

      project_id = input[:project_id]
      issue_id = input[:issue_id]
      custom_prompt = input[:custom_prompt]
      provider_id = input[:provider_id]
      goal = input[:goal]
      source_pull_request_number = input[:source_pull_request_number]
      count_toward_draft_review_round = input.fetch(:count_toward_draft_review_round, false)
      expected_draft_review_count = input[:expected_draft_review_count]

      project = Project.find(project_id)
      goal ||= project.account.tenant_setting&.default_goal || "create_pr"
      issue = issue_id ? Issue.find(issue_id) : nil
      user_settings = resolve_user_settings(project)
      provider_selection_options = {
        project: project,
        issue: issue,
        goal: goal,
        requested_agent_type: input[:agent_type],
        requested_provider_id: input[:provider_id],
        respect_requested: input.key?(:agent_type) || input.key?(:provider_id)
      }
      provider_id, agent_type = resolve_and_validate_provider_selection!(**provider_selection_options)

      # Resolve and render prompt version if no custom prompt is provided.
      # Skip for untrusted issues to match the safety behavior in AgentRun#prompt_for_issue.
      prompt_version = nil
      if custom_prompt.blank? && issue.present? && issue.trusted?
        prompt_version = Prompts::Resolve.call(slug: "coding.issue_implementation", project: project)
        if prompt_version
          # The activity appends a full `# Service Environment` section after
          # the rendered template (see below), so we suppress the inline
          # `{{setup_database_instruction}}` slot to avoid duplicating the
          # database setup line. BuildForIssue uses the opposite split: it
          # fills the inline slot and skips the header in the appended block.
          rendered_prompt = prompt_version.render(
            title: issue.title,
            issue_number: issue.github_number.to_s,
            body: issue.body.to_s,
            test_command: test_command_for(project),
            lint_command: lint_command_for(project),
            setup_database_instruction: ""
          )
          custom_prompt = [
            rendered_prompt,
            # Append trusted issue comments so they reach the agent even when
            # the rendered PromptVersion is stored as custom_prompt (which
            # bypasses BuildForIssue in effective_prompt).
            Prompts::BuildForIssue.conversation_section_for(
              project: project, issue: issue,
              github_client: project.github_token&.client
            ),
            Prompts::BuildForIssue.service_environment_section_for(project: project)
          ].reject(&:blank?).join("\n\n")
        end
      end

      scope_result = analyze_scope(issue)

      attrs = {
        project: project,
        issue: issue,
        provider_id: provider_id,
        agent_type: agent_type,
        goal: goal,
        custom_prompt: custom_prompt,
        source_pull_request_number: source_pull_request_number,
        count_toward_draft_review_round: count_toward_draft_review_round,
        expected_draft_review_count: expected_draft_review_count,
        prompt_version: prompt_version,
        status: "queued",
        temporal_workflow_id: input[:workflow_id] || AgentRun::CLAIMED_SENTINEL
      }
      attrs[:parent_workflow_id] = input[:parent_workflow_id] if input[:parent_workflow_id]

      agent_run = AgentRun.create!(**attrs)
      log_provider_selection(agent_run: agent_run, **provider_selection_options, resolved_provider_id: provider_id, resolved_agent_type: agent_type)

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
        assign_configuration_bundle(agent_run)

        log_scope_analysis(agent_run, scope_result)

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
          provider_attempt_count: provider_attempt_count_for(agent_run, user_settings),
          agent_timeout_seconds: user_settings&.agent_timeout_seconds || AGENT_TIMEOUT_DEFAULT,
          issue_goal_timeout_seconds: user_settings&.issue_goal_timeout_seconds || Activities::RunAgentActivity::DEFAULT_ISSUE_GOAL_TIMEOUT,
          max_execution_seconds: effective_max_execution_seconds(project, user_settings),
          scope_analysis: scope_result ? {
            should_decompose: scope_result.should_decompose?,
            confidence: scope_result.confidence,
            sub_components: scope_result.sub_components
          } : nil
        }
      end
    end

    private

    def resolve_provider_selection(project:, requested_agent_type:, requested_provider_id:, goal:, respect_requested: true)
      AgentRuns::ProviderResolver.call(
        project: project,
        goal: goal,
        requested_agent_type: requested_agent_type,
        requested_provider_id: requested_provider_id,
        respect_requested: respect_requested,
        logger: logger
      )
    end

    def resolve_and_validate_provider_selection!(project:, issue:, requested_agent_type:, requested_provider_id:, goal:, respect_requested:)
      provider_id = nil
      agent_type = nil
      provider_id, agent_type = resolve_provider_selection(
        project: project,
        requested_agent_type: requested_agent_type,
        requested_provider_id: requested_provider_id,
        goal: goal,
        respect_requested: respect_requested
      )

      validate_requested_provider_resolution!(
        project: project,
        requested_provider_id: requested_provider_id,
        resolved_provider_id: provider_id
      )

      validate_runnable_provider!(project: project, provider_id: provider_id, agent_type: agent_type, goal: goal)
      [ provider_id, agent_type ]
    rescue Temporalio::Error::ApplicationError => error
      log_provider_selection(
        project: project,
        issue: issue,
        goal: goal,
        requested_agent_type: requested_agent_type,
        requested_provider_id: requested_provider_id,
        respect_requested: respect_requested,
        resolved_provider_id: provider_id,
        resolved_agent_type: agent_type,
        outcome: "failed",
        error: error
      )
      raise
    end

    def refresh_automatic_run_provider!(agent_run)
      return [ agent_run.provider_id, agent_run.agent_type ] unless agent_run.automatic?

      resolve_provider_selection(
        project: agent_run.project,
        requested_agent_type: nil,
        requested_provider_id: nil,
        goal: agent_run.goal,
        respect_requested: false
      )
    end

    def resume_queued_run(agent_run_id)
      agent_run = AgentRun.find(agent_run_id)
      provider_changed = false

      if agent_run.queued?
        provider_changed = validate_and_sync_resumed_provider!(agent_run)
      else
        logger.warn(
          message: "agent_execution.resume_queued_run_unexpected_status",
          agent_run_id: agent_run.id,
          current_status: agent_run.status,
          project_id: agent_run.project_id
        )
      end

      agent_run.issue&.update!(paid_state: "in_progress")
      select_model(agent_run) unless agent_run.model_selection
      assign_configuration_bundle(agent_run) if provider_changed || agent_run.configuration_bundle.blank?

      logger.info(
        message: "agent_execution.queued_run_resumed",
        agent_run_id: agent_run.id,
        project_id: agent_run.project_id,
        issue_id: agent_run.issue_id
      )

      user_settings = resolve_user_settings(agent_run.project)
      {
        agent_run_id: agent_run.id,
        provider_attempt_count: provider_attempt_count_for(agent_run, user_settings),
        agent_timeout_seconds: user_settings&.agent_timeout_seconds || AGENT_TIMEOUT_DEFAULT,
        issue_goal_timeout_seconds: user_settings&.issue_goal_timeout_seconds || Activities::RunAgentActivity::DEFAULT_ISSUE_GOAL_TIMEOUT,
        max_execution_seconds: effective_max_execution_seconds(agent_run.project, user_settings)
      }
    end

    def analyze_scope(issue)
      return unless issue&.body.present?

      ScopeAnalysis::Analyze.call(text: issue.body)
    end

    def log_scope_analysis(agent_run, scope_result)
      return unless scope_result

      logger.info(
        message: "agent_execution.scope_analysis_complete",
        agent_run_id: agent_run.id,
        should_decompose: scope_result.should_decompose?,
        confidence: scope_result.confidence,
        sub_components: scope_result.sub_components
      )
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

    def assign_configuration_bundle(agent_run)
      ConfigurationBundles::AssignToRun.call(agent_run: agent_run)
    end

    def resolve_user_settings(project)
      AgentRuns::UserSettingsResolver.call(project: project, strict: false)
    end

    def log_provider_selection(project:, goal:, resolved_agent_type:, resolved_provider_id:, issue: nil, agent_run: nil,
      requested_agent_type: nil, requested_provider_id: nil, respect_requested: false, outcome: "selected", error: nil)
      AgentRuns::ProviderSelectionLogger.call(
        project: project,
        issue: issue,
        agent_run: agent_run,
        goal: goal,
        requested_agent_type: requested_agent_type,
        requested_provider_id: requested_provider_id,
        respect_requested: respect_requested,
        resolved_provider_id: resolved_provider_id,
        resolved_agent_type: resolved_agent_type,
        outcome: outcome,
        error: error
      )
    end

    def provider_attempt_count_for(agent_run, user_settings)
      Activities::RunAgentActivity.provider_attempt_count_for_run(
        agent_run: agent_run,
        user_settings: user_settings
      )
    end

    def effective_max_execution_seconds(project, user_settings)
      user_settings&.max_execution_seconds || project.max_execution_seconds
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

    def validate_runnable_provider!(project:, provider_id:, agent_type:, goal:)
      return if goal.in?(NON_CONTAINER_GOALS)

      provider = resolved_provider!(project: project, provider_id: provider_id)
      if provider
        raise_no_runnable_provider!(
          "No runnable provider available for project (provider_id=#{provider.id}, enabled_for_agent_runs=#{provider.enabled_for_agent_runs?})"
        ) unless provider.enabled_for_agent_runs?

        warn_if_rate_limited(provider, project: project, goal: goal)
        return
      end

      provider_key = ProviderSupport.provider_key_for_agent_type(agent_type)
      return if ProviderSupport.container_executable_provider_key?(provider_key)

      raise_no_runnable_provider!("No runnable provider available for project (agent_type=#{agent_type})")
    end

    def resolved_provider!(project:, provider_id:)
      provider = AgentRuns::ProviderResolver.selected_provider(project: project, provider_id: provider_id)
      raise_unresolved_provider!(project: project, provider_id: provider_id) if provider_id.present? && provider.nil?

      provider
    end

    def validate_requested_provider_resolution!(project:, requested_provider_id:, resolved_provider_id:)
      return if requested_provider_id.blank?
      return if requested_provider_id.to_s == resolved_provider_id.to_s
      return if AgentRuns::ProviderResolver.selected_provider(project: project, provider_id: requested_provider_id)

      raise_unresolved_provider!(project: project, provider_id: requested_provider_id)
    end

    def raise_unresolved_provider!(project:, provider_id:)
      return if provider_id.blank?

      raise_no_runnable_provider!("No runnable provider available for project (project_id=#{project.id}, provider_id=#{provider_id}, resolved=false)")
    end

    def warn_if_rate_limited(provider, project:, goal:)
      provider_state = provider.user.provider_states.find_by(provider_name: provider.state_key)
      return unless provider_state&.rate_limited?

      logger.warn(
        message: "agent_execution.selected_provider_rate_limited",
        project_id: project.id,
        provider_id: provider.id,
        provider_key: provider.provider_key,
        provider_state_name: provider.state_key,
        agent_type: Provider.agent_type_for(provider.provider_key),
        goal: goal,
        rate_limited_until: provider_state.rate_limited_until
      )
    end

    def validate_and_sync_resumed_provider!(agent_run)
      provider_id, agent_type = refresh_automatic_run_provider!(agent_run)
      validate_runnable_provider!(
        project: agent_run.project,
        provider_id: provider_id,
        agent_type: agent_type,
        goal: agent_run.goal
      )
      sync_provider_selection!(agent_run, provider_id: provider_id, agent_type: agent_type)
    end

    def sync_provider_selection!(agent_run, provider_id:, agent_type:)
      return false if agent_run.provider_id == provider_id && agent_run.agent_type == agent_type

      agent_run.update!(
        provider: Provider.kept_only.find_by(id: provider_id),
        agent_type: agent_type
      )
      true
    end

    def raise_no_runnable_provider!(message)
      raise Temporalio::Error::ApplicationError.new(
        message,
        type: "NoRunnableProvider",
        non_retryable: true
      )
    end
  end
end
