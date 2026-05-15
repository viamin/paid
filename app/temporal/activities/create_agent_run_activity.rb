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
      provider_id = input[:runner_id]
      goal = input[:goal]
      focus = input[:focus] || "general"
      source_pull_request_number = input[:source_pull_request_number]
      count_toward_draft_review_round = input.fetch(:count_toward_draft_review_round, false)
      expected_draft_review_count = input[:expected_draft_review_count]

      project = Project.find(project_id)
      goal ||= project.account.tenant_setting&.default_goal || "create_pr"
      issue = issue_id ? Issue.find(issue_id) : nil
      user_settings = resolve_user_settings(project)
      runner_selection_options = {
        project: project,
        issue: issue,
        goal: goal,
        requested_agent_type: input[:agent_type],
        requested_runner_id: input[:runner_id],
        respect_requested: input.key?(:agent_type) || input.key?(:runner_id)
      }
      provider_id, agent_type = resolve_and_validate_runner_selection!(**runner_selection_options)

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
        runner_id: provider_id,
        agent_type: agent_type,
        goal: goal,
        custom_prompt: custom_prompt,
        source_pull_request_number: source_pull_request_number,
        count_toward_draft_review_round: count_toward_draft_review_round,
        expected_draft_review_count: expected_draft_review_count,
        focus: focus,
        prompt_version: prompt_version,
        status: "queued",
        temporal_workflow_id: input[:workflow_id] || AgentRun::CLAIMED_SENTINEL
      }
      attrs[:parent_workflow_id] = input[:parent_workflow_id] if input[:parent_workflow_id]

      agent_run = AgentRun.create!(**attrs)
      log_runner_selection(agent_run: agent_run, **runner_selection_options, resolved_runner_id: provider_id, resolved_agent_type: agent_type)

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
          focus: agent_run.focus,
          runner_attempt_count: runner_attempt_count_for(agent_run, user_settings),
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

    def resolve_runner_selection(project:, requested_agent_type:, requested_runner_id:, goal:, respect_requested: true)
      AgentRuns::RunnerResolver.call(
        project: project,
        goal: goal,
        requested_agent_type: requested_agent_type,
        requested_runner_id: requested_runner_id,
        respect_requested: respect_requested,
        logger: logger
      )
    end

    def resolve_and_validate_runner_selection!(project:, issue:, requested_agent_type:, requested_runner_id:, goal:, respect_requested:)
      provider_id = nil
      agent_type = nil
      provider_id, agent_type = resolve_runner_selection(
        project: project,
        requested_agent_type: requested_agent_type,
        requested_runner_id: requested_runner_id,
        goal: goal,
        respect_requested: respect_requested
      )

      validate_requested_runner_resolution!(
        project: project,
        requested_runner_id: requested_runner_id,
        resolved_runner_id: provider_id
      )

      validate_runnable_runner!(project: project, runner_id: provider_id, agent_type: agent_type, goal: goal)
      [ provider_id, agent_type ]
    rescue Temporalio::Error::ApplicationError => error
      log_runner_selection(
        project: project,
        issue: issue,
        goal: goal,
        requested_agent_type: requested_agent_type,
        requested_runner_id: requested_runner_id,
        respect_requested: respect_requested,
        resolved_runner_id: provider_id,
        resolved_agent_type: agent_type,
        outcome: "failed",
        error: error
      )
      raise
    end

    def refresh_automatic_run_runner!(agent_run)
      return [ agent_run.runner_id, agent_run.agent_type ] unless agent_run.automatic?

      resolve_runner_selection(
        project: agent_run.project,
        requested_agent_type: nil,
        requested_runner_id: nil,
        goal: agent_run.goal,
        respect_requested: false
      )
    end

    def resume_queued_run(agent_run_id)
      agent_run = AgentRun.find(agent_run_id)

      if agent_run.queued?
        validate_and_sync_resumed_runner!(agent_run)
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
      assign_configuration_bundle(agent_run)

      logger.info(
        message: "agent_execution.queued_run_resumed",
        agent_run_id: agent_run.id,
        project_id: agent_run.project_id,
        issue_id: agent_run.issue_id
      )

      user_settings = resolve_user_settings(agent_run.project)
      {
        agent_run_id: agent_run.id,
        focus: agent_run.focus,
        runner_attempt_count: runner_attempt_count_for(agent_run, user_settings),
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

    def log_runner_selection(project:, goal:, resolved_agent_type:, resolved_runner_id:, issue: nil, agent_run: nil,
      requested_agent_type: nil, requested_runner_id: nil, respect_requested: false, outcome: "selected", error: nil)
      AgentRuns::RunnerSelectionLogger.call(
        project: project,
        issue: issue,
        agent_run: agent_run,
        goal: goal,
        requested_agent_type: requested_agent_type,
        requested_runner_id: requested_runner_id,
        respect_requested: respect_requested,
        resolved_runner_id: resolved_runner_id,
        resolved_agent_type: resolved_agent_type,
        outcome: outcome,
        error: error
      )
    end

    def runner_attempt_count_for(agent_run, user_settings)
      Activities::RunAgentActivity.runner_attempt_count_for_run(
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

    def validate_runnable_runner!(project:, runner_id:, agent_type:, goal:)
      return if goal.in?(NON_CONTAINER_GOALS)

      runner = resolved_runner!(project: project, runner_id: runner_id)
      if runner
        raise_no_runnable_provider!(
          "No runnable runner available for project (runner_id=#{runner.id}, enabled_for_agent_runs=#{runner.enabled_for_agent_runs?})"
        ) unless runner.enabled_for_agent_runs?

        warn_if_rate_limited(runner, project: project, goal: goal)
        return
      end

      provider_key = RunnerSupport.runner_key_for_agent_type(agent_type)
      return if RunnerSupport.container_executable_runner_key?(provider_key)

      raise_no_runnable_provider!("No runnable runner available for project (agent_type=#{agent_type})")
    end

    def resolved_runner!(project:, runner_id:)
      runner = AgentRuns::RunnerResolver.selected_runner(project: project, runner_id: runner_id)
      raise_unresolved_runner!(project: project, runner_id: runner_id) if runner_id.present? && runner.nil?

      runner
    end

    def validate_requested_runner_resolution!(project:, requested_runner_id:, resolved_runner_id:)
      return if requested_runner_id.blank?
      return if requested_runner_id.to_s == resolved_runner_id.to_s
      return if AgentRuns::RunnerResolver.selected_runner(project: project, runner_id: requested_runner_id)

      raise_unresolved_runner!(project: project, runner_id: requested_runner_id)
    end

    def raise_unresolved_runner!(project:, runner_id:)
      return if runner_id.blank?

      raise_no_runnable_provider!("No runnable runner available for project (project_id=#{project.id}, runner_id=#{runner_id}, resolved=false)")
    end

    def warn_if_rate_limited(runner, project:, goal:)
      runner_state = runner.user.runner_states.find_by(runner_name: runner.state_key)
      return unless runner_state&.rate_limited?

      logger.warn(
        message: "agent_execution.selected_runner_rate_limited",
        project_id: project.id,
        runner_id: runner.id,
        runner_key: runner.runner_key,
        runner_state_name: runner.state_key,
          agent_type: Runner.agent_type_for(runner.runner_key),
        goal: goal,
        rate_limited_until: runner_state.rate_limited_until
      )
    end

    def validate_and_sync_resumed_runner!(agent_run)
      provider_id, agent_type = refresh_automatic_run_runner!(agent_run)
      validate_runnable_runner!(
        project: agent_run.project,
        runner_id: provider_id,
        agent_type: agent_type,
        goal: agent_run.goal
      )
      sync_runner_selection!(agent_run, runner_id: provider_id, agent_type: agent_type)
    end

    def sync_runner_selection!(agent_run, runner_id:, agent_type:)
      return false if agent_run.runner_id == runner_id && agent_run.agent_type == agent_type

      agent_run.update!(
        runner: Runner.kept_only.find_by(id: runner_id),
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
