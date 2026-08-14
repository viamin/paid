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
      manual_marketplace_entry_ids = input[:marketplace_entry_ids]
      plan_docs = normalize_plan_docs(input[:plan_docs])

      project = Project.find(project_id)
      goal ||= project.account.tenant_setting&.default_goal || "create_pr"
      issue = issue_id ? Issue.find(issue_id) : nil
      custom_prompt = build_lid_planning_prompt(project: project, custom_prompt: custom_prompt, plan_docs: plan_docs, goal: goal)
      ensure_trusted_issue_for_non_container_goal!(issue, goal)
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

      # Resolve the create_pr issue template version when no custom prompt is
      # provided. The queued run records the chosen PromptVersion for audit,
      # but leaves custom_prompt blank so runner-time PromptAssembly can build
      # the issue prompt with provenance.
      prompt_version = nil
      service_environment_prompt_blocks = []
      if goal == "create_pr" && custom_prompt.blank? && issue.present? && issue.trusted?
        prompt_version = Prompts::Resolve.call(slug: "coding.issue_implementation", project: project)
        if prompt_version
          service_environment = Prompts::BuildForIssue.service_environment_section_render_for(project: project)
          service_environment_prompt_blocks = service_environment.prompt_blocks
        end
      end

      scope_result = analyze_scope(issue)

      attrs = {
        project: project,
        issue: issue,
        initiating_user_id: input[:initiating_user_id],
        runner_id: provider_id,
        agent_type: agent_type,
        goal: goal,
        custom_prompt: custom_prompt,
        source_pull_request_number: source_pull_request_number,
        count_toward_draft_review_round: count_toward_draft_review_round,
        expected_draft_review_count: expected_draft_review_count,
        focus: focus,
        prompt_version: prompt_version,
        external_metadata: build_external_metadata(plan_docs: plan_docs),
        status: "queued",
        temporal_workflow_id: input[:workflow_id] || AgentRun::CLAIMED_SENTINEL
      }
      attrs[:parent_workflow_id] = input[:parent_workflow_id] if input[:parent_workflow_id]

      agent_run = ActiveRecord::Base.transaction do
        created_run = find_or_create_agent_run(attrs)
        maybe_inject_style_guides!(
          agent_run: created_run,
          prompt_version: prompt_version,
          custom_prompt_provided: input[:custom_prompt].present?
        )
        attach_marketplace_entries(
          agent_run: created_run,
          manual_entry_ids: manual_marketplace_entry_ids,
          auto_attach_enabled: marketplace_auto_attach_enabled?(user_settings),
          account_auto_attach_required: marketplace_auto_attach_required?(project)
        )
        created_run
      end
      log_runner_selection(agent_run: agent_run, **runner_selection_options, resolved_runner_id: provider_id, resolved_agent_type: agent_type)

      track_phase(
        agent_run_id: agent_run.id,
        agent_run: agent_run,
        phase_key: "create_agent_run",
        phase_group: "prompt",
        metadata: {
          prompt_version_id: prompt_version&.id,
          service_environment_prompt_blocks: service_environment_prompt_blocks,
          custom_prompt_provided: input[:custom_prompt].present?
        },
        started_at: agent_run.created_at
      ) do
        if goal == "create_feature" && issue.present? && feature_brief_sparse?(agent_run)
          initiate_feature_needs_input!(agent_run, project, issue)
          next build_result(agent_run, user_settings, project, scope_result, paused: true)
        end

        issue&.update!(paid_state: "in_progress")

        # Select model for this run (creates a ModelSelection record for cost
        # tracking and audit). Non-fatal — runs proceed with default pricing
        # if no LlmModel records exist yet.
        select_model(agent_run)
        policy_evaluation = apply_policy_controls(agent_run)
        assign_configuration_bundle(agent_run)
        select_and_log_orchestration_strategy(agent_run)

        log_scope_analysis(agent_run, scope_result)

        logger.info(
          message: "agent_execution.agent_run_created",
          agent_run_id: agent_run.id,
          project_id: project_id,
          issue_id: issue_id,
          custom_prompt_provided: input[:custom_prompt].present?,
          prompt_version_id: prompt_version&.id
        )

        result = build_result(agent_run, user_settings, project, scope_result, paused: policy_evaluation.paused)
        result
      end
    end

    private

    def ensure_trusted_issue_for_non_container_goal!(issue, goal)
      return unless issue.present? && NON_CONTAINER_GOALS.include?(goal)
      return if issue.trusted?

      logger.warn(
        message: "agent_execution.untrusted_issue_rejected",
        issue_id: issue.id,
        goal: goal,
        creator: issue.github_creator_login
      )
      raise Temporalio::Error::ApplicationError.new(
        "Cannot queue #{goal} for issue from untrusted user: #{issue.github_creator_login}",
        type: "UntrustedIssue",
        non_retryable: true
      )
    end

    # Idempotent on Temporal retry: when the workflow passes a real
    # `temporal_workflow_id`, reuse the AgentRun a previous attempt already
    # created instead of inserting a duplicate. The CLAIMED_SENTINEL fallback
    # (and a nil workflow id) cannot be used as a dedup key, so those paths
    # fall back to a plain create. Marketplace attachment and the post-create
    # setup steps are all idempotent when re-run against the same run.
    def find_or_create_agent_run(attrs)
      workflow_id = attrs[:temporal_workflow_id]
      return AgentRun.create!(**attrs) if workflow_id.blank? || workflow_id == AgentRun::CLAIMED_SENTINEL

      AgentRun.find_or_create_by!(temporal_workflow_id: workflow_id) do |run|
        run.assign_attributes(attrs)
      end
    end

    def resolve_runner_selection(project:, requested_agent_type:, requested_runner_id:, goal:, respect_requested: true,
                                effective_runner: nil)
      AgentRuns::RunnerResolver.call(
        project: project,
        goal: goal,
        requested_agent_type: requested_agent_type,
        requested_runner_id: requested_runner_id,
        respect_requested: respect_requested,
        effective_runner: effective_runner,
        logger: logger
      )
    end

    def build_external_metadata(plan_docs:)
      return {} if plan_docs.empty?

      { "plan_docs" => plan_docs }
    end

    def normalize_plan_docs(raw_docs)
      Array(raw_docs).filter_map do |doc|
        next unless doc.respond_to?(:[])

        name = doc[:name] || doc["name"]
        { "name" => name.to_s } if name.present?
      end
    end

    def build_lid_planning_prompt(project:, custom_prompt:, plan_docs:, goal:)
      return custom_prompt unless goal == "lid_planning"
      return custom_prompt if custom_prompt.present?

      Prompts::BuildForLidPlanning.call(
        project_name: project.full_name,
        project_description: Prompts::BuildForLidPlanning.project_description_for(project),
        plan_docs: plan_docs,
        adoption: project.lid_mode.blank?
      )
    end

    # Resumed queued runs were created by the controller/MCP, which stores
    # plan_docs in external_metadata but leaves custom_prompt blank for
    # lid_planning goals. Build and persist the prompt eagerly so
    # apply_policy_controls and the audit trail see the same prompt the
    # create path produces.
    def ensure_lid_planning_prompt!(agent_run)
      return unless agent_run.lid_planning_goal? && agent_run.custom_prompt.blank?

      plan_docs = agent_run.external_metadata.fetch("plan_docs", [])
      prompt = build_lid_planning_prompt(
        project: agent_run.project,
        custom_prompt: nil,
        plan_docs: plan_docs,
        goal: agent_run.goal
      )
      agent_run.update!(custom_prompt: prompt) if prompt.present?
    end

    def maybe_inject_style_guides!(agent_run:, prompt_version:, custom_prompt_provided:)
      prompt = agent_run.custom_prompt
      return if prompt.blank?
      return if custom_prompt_provided || prompt_version.nil?

      prompt = StyleGuides::InjectIntoPrompt.call(
        prompt: prompt,
        project: agent_run.project,
        agent_run: agent_run,
        source: self.class.name
      )
      prompt = ProjectConventions::InjectIntoPrompt.call(prompt: prompt, project: agent_run.project)
      return if prompt == agent_run.custom_prompt

      agent_run.update!(custom_prompt: prompt)
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
        respect_requested: false,
        effective_runner: agent_run.effective_runner
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

      # RDR-053: If this is a create_feature run with a sparse brief,
      # post clarifying questions and pause before the agent begins work.
      if agent_run.create_feature_goal? && agent_run.issue.present? && feature_brief_sparse?(agent_run)
        initiate_feature_needs_input!(agent_run, agent_run.project, agent_run.issue)
        return {
          agent_run_id: agent_run.id,
          focus: agent_run.focus,
          runner_attempt_count: 1,
          agent_timeout_seconds: AGENT_TIMEOUT_DEFAULT,
          max_execution_seconds: effective_max_execution_seconds(agent_run.project, nil),
          paused: true
        }
      end

      agent_run.issue&.update!(paid_state: "in_progress")
      select_model(agent_run) unless agent_run.model_selection
      ensure_lid_planning_prompt!(agent_run)
      user_settings = resolve_user_settings(agent_run.project)
      attach_marketplace_entries_for_resume(
        agent_run: agent_run,
        user_settings: user_settings,
        force: false,
        account_auto_attach_required: marketplace_auto_attach_required?(agent_run.project)
      )
      policy_evaluation = apply_policy_controls(agent_run)
      assign_configuration_bundle(agent_run)
      select_and_log_orchestration_strategy(agent_run)

      logger.info(
        message: "agent_execution.queued_run_resumed",
        agent_run_id: agent_run.id,
        account_id: agent_run.project.account_id,
        project_id: agent_run.project_id,
        issue_id: agent_run.issue_id,
        schedule_to_start_seconds: schedule_to_start_seconds(agent_run)
      )
      record_schedule_to_start_metric(agent_run)

      {
        agent_run_id: agent_run.id,
        focus: agent_run.focus,
        runner_attempt_count: runner_attempt_count_for(agent_run, user_settings),
        agent_timeout_seconds: user_settings&.agent_timeout_seconds || AGENT_TIMEOUT_DEFAULT,
        issue_goal_timeout_seconds: user_settings&.issue_goal_timeout_seconds || Activities::RunAgentActivity::DEFAULT_ISSUE_GOAL_TIMEOUT,
        max_execution_seconds: effective_max_execution_seconds(agent_run.project, user_settings),
        paused: policy_evaluation.paused
      }
    end

    def record_schedule_to_start_metric(agent_run)
      agent_run.log!(
        "metric",
        {
          metric_name: "schedule_to_start_latency",
          seconds: schedule_to_start_seconds(agent_run),
          account_id: agent_run.project.account_id,
          project_id: agent_run.project_id,
          queue: Paid.agent_task_queue
        }.to_json,
        metadata: { type: "schedule_to_start_latency", account_id: agent_run.project.account_id }
      )
    end

    def schedule_to_start_seconds(agent_run)
      [ (Time.current - agent_run.queue_entered_at_for_current_episode).to_f, 0.0 ].max.round(3)
    end

    def analyze_scope(issue)
      return unless issue&.body.present?

      ScopeAnalysis::Analyze.call(text: issue.body)
    end

    def attach_marketplace_entries_for_resume(agent_run:, user_settings:, force: false, account_auto_attach_required: false)
      attachments = agent_run.agent_run_marketplace_entries
      return rerender_marketplace_entries_for_resume(
        agent_run: agent_run,
        account_auto_attach_required: account_auto_attach_required
      ) if attachments.exists? && force
      return if attachments.exists?
      return unless should_attach_marketplace_entries_on_resume?(agent_run, account_auto_attach_required)

      attach_marketplace_entries(
        agent_run: agent_run,
        auto_attach_enabled: marketplace_auto_attach_enabled?(user_settings),
        account_auto_attach_required: account_auto_attach_required
      )
    end

    def attach_marketplace_entries(agent_run:, auto_attach_enabled:, manual_entry_ids: nil, account_auto_attach_required: false)
      MarketplaceEntries::AttachToRun.call(
        agent_run: agent_run,
        manual_entry_ids: manual_entry_ids,
        auto_attach_enabled: auto_attach_enabled,
        account_auto_attach_required: account_auto_attach_required
      )
    rescue => e
      log_marketplace_attachment_failure(agent_run: agent_run, error: e)
      raise if account_auto_attach_required || Array(manual_entry_ids).any?
      raise unless ignorable_marketplace_attachment_error?(e)
    end

    def rerender_marketplace_entries_for_resume(agent_run:, account_auto_attach_required: false)
      MarketplaceEntries::RerenderForRun.call(agent_run: agent_run)
    rescue => e
      log_marketplace_attachment_failure(agent_run: agent_run, error: e)
      raise if account_auto_attach_required
      raise unless ignorable_marketplace_attachment_error?(e)
    end

    def should_attach_marketplace_entries_on_resume?(agent_run, account_auto_attach_required)
      return true if account_auto_attach_required
      return false if agent_run.manual?

      true
    end

    def log_marketplace_attachment_failure(agent_run:, error:)
      logger.warn(
        message: "agent_execution.marketplace_attachment_failed",
        agent_run_id: agent_run.id,
        error_class: error.class.name,
        error: error.message
      )
    end

    def ignorable_marketplace_attachment_error?(error)
      error.is_a?(ActiveRecord::RecordNotFound) || error.is_a?(ActiveRecord::RecordInvalid)
    end

    def marketplace_auto_attach_enabled?(user_settings)
      user_settings&.marketplace_auto_attach_enabled?
    end

    def marketplace_auto_attach_required?(project)
      project.account.tenant_setting&.marketplace_auto_attach_required?
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

    def select_and_log_orchestration_strategy(agent_run)
      result = Strategies::Select.call(
        decision_type: "issue_execution",
        project: agent_run.project,
        task_type: agent_run.goal,
        context: {
          "goal" => agent_run.goal,
          "agent_type" => agent_run.agent_type,
          "focus" => agent_run.focus
        }
      )

      OrchestrationDecision.create!(
        project: agent_run.project,
        agent_run: agent_run,
        decision_type: "issue_execution",
        actor: self.class.name,
        strategy_version: result.strategy_version,
        context: {
          "decision_status" => result.found? ? "applied" : "noop",
          "scope" => result.scope.to_s,
          "strategy" => result.to_s,
          "matched_rule_count" => result.matched_rule_count
        },
        inputs: {
          "goal" => agent_run.goal,
          "agent_type" => agent_run.agent_type,
          "focus" => agent_run.focus
        },
        outputs: result.content,
        outcome_references: []
      )
    rescue => e
      logger.warn(
        message: "agent_execution.orchestration_strategy_selection_failed",
        agent_run_id: agent_run.id,
        error_class: e.class.name,
        error: e.message
      )
    end

    def apply_policy_controls(agent_run)
      evaluation = PolicyControls::Evaluate.call(
        project: agent_run.project,
        issue: agent_run.issue,
        goal: agent_run.goal,
        runner: agent_run.runner,
        model: agent_run.model_selection&.llm_model,
        prompt: agent_run.custom_prompt,
        target_branch: agent_run.project.default_branch,
        service_containers: agent_run.project.service_containers
      )

      attributes = {
        guardrail_context: agent_run.guardrail_context.to_h.merge(
          "policy_controls" => evaluation.to_h
        )
      }
      if agent_run.custom_prompt.present? || evaluation.sanitized_prompt.present?
        attributes[:custom_prompt] = evaluation.sanitized_prompt if evaluation.sanitized_prompt != agent_run.custom_prompt
      end

      if evaluation.paused
        attributes[:status] = "paused"
        attributes[:paused_at] = Time.current
        attributes[:error_message] = evaluation.reason
      end

      agent_run.update!(attributes)

      return evaluation unless evaluation.paused

      logger.info(
        message: "agent_execution.policy_controls_paused",
        agent_run_id: agent_run.id,
        project_id: agent_run.project_id,
        reason: evaluation.reason,
        risk_score: evaluation.risk_score
      )
      evaluation
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

    # @spec POLYGLOT-TEST-003
    def test_command_for(project)
      Prompts::LanguageCommands.format_for_prompt(Prompts::LanguageCommands.test_commands_for(project))
    end

    # @spec POLYGLOT-TEST-003
    def lint_command_for(project)
      Prompts::LanguageCommands.format_for_prompt(Prompts::LanguageCommands.lint_commands_for(project))
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
    # Returns a result hash for CreateAgentRunActivity, factoring in pause state.
    def build_result(agent_run, user_settings, project, scope_result, paused: false)
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
        } : nil,
        paused: paused
      }
    end

    # A feature brief is considered sparse when it lacks the structured fields
    # beyond the initial title/problem. The user provided only a description;
    # the run should pause and ask clarifying questions before proceeding.
    def feature_brief_sparse?(agent_run)
      brief = agent_run.external_metadata.is_a?(Hash) ? agent_run.external_metadata["feature_brief"] : nil
      return true if brief.blank?

      # If the brief only has title and a free-text description, it's sparse.
      required_fields = %w[desired_behavior constraints scope done_criteria]
      required_fields.any? { |field| brief[field].blank? }
    end

    # Posts intent-focused clarifying questions on the feature's GitHub issue,
    # applies the needs-input label, and pauses the run so the user can answer
    # before the agent begins work.
    def initiate_feature_needs_input!(agent_run, project, issue)
      question_comment = build_feature_clarifying_questions_comment
      client = project.client

      if client
        client.add_comment(project.full_name, issue.github_number, question_comment)
        label = project.enhance_issue_needs_input_label_name
        client.add_labels_to_issue(project.full_name, issue.github_number, [ label ])
        # Persist the parsed questions locally so the dashboard needs-input
        # queue can render them without a per-issue GitHub API round-trip.
        questions = ClarifyingQuestions::Parse.call(comment_body: question_comment)
        issue.update!(
          paid_state: "needs_input",
          labels: Array(issue.labels) | [ label ],
          needs_input_questions: questions
        )
      end

      agent_run.update!(status: "paused", paused_at: Time.current)

      logger.info(
        message: "agent_execution.create_feature_needs_input",
        agent_run_id: agent_run.id,
        issue_id: issue.id,
        issue_number: issue.github_number
      )
    end

    # Builds a clarifying questions comment for a create_feature run.
    # The questions follow the intent-focused pattern from RDR-051,
    # covering problem, desired behavior, constraints, alternatives,
    # scope, and done-ness — the fields that make up a complete
    # feature brief (RDR-053 §2).
    def build_feature_clarifying_questions_comment
      marker = "<!-- paid:enhance-issue -->"
      questions = [
        "What is the desired behavior? Describe what the feature should do from the user's perspective.",
        "What constraints must be respected? List any technical, design, or business constraints.",
        "What alternatives have been considered and rejected? This helps avoid re-litigating decisions.",
        "What is in scope and out of scope? Be explicit about boundaries.",
        "How will we know it's done? Define concrete acceptance criteria."
      ]
      question_lines = questions.each_with_index.map { |q, i| "#{i + 1}. #{q}" }.join("\n")

      <<~COMMENT
        #{marker}

        ## Clarifying questions

        Thanks for the feature description! Before I research and write a full specification, I need a bit more detail to make sure I design the right thing.

        #{question_lines}

        Please reply to this issue with your answers. Once all questions are addressed, the agent will resume and create the feature specification.
      COMMENT
    end
  end
end
