# frozen_string_literal: true

module Projects
  class AgentRunsController < ApplicationController
    include AgentRunCancellable

    NoRunnableProviderError = Class.new(StandardError)

    before_action :set_project
    before_action :set_agent_run, only: [ :show, :cancel, :retry, :refresh_auth, :diagnose_error, :resume, :terminate ]

    def index
      authorize @project, :show?
      base_scope = @project.agent_runs.includes(:provider, project: [ :created_by, :account ], issue: :project)
      @q = base_scope.ransack(params[:q])
      @q.sorts = "created_at desc" if @q.sorts.empty?
      @pagy, @agent_runs = pagy(@q.result)
      AgentRun.preload_final_provider_records(@agent_runs)
      AgentRun.preload_source_pull_requests(@agent_runs)
      AgentRun.preload_created_issue_records(@agent_runs)
      cache_key = AgentRun.provider_options_cache_key_for(account_id: @project.account_id, project_id: @project.id)
      @provider_options = base_scope.distinct_effective_provider_options(account_id: @project.account_id, cache_key: cache_key)
    end

    def show
      authorize @agent_run
      @retry_provider_options = retry_provider_options_for(@agent_run)
      @quality_metrics = @agent_run.quality_metrics.with_composite_score.load
      @logs = @agent_run.agent_run_logs.order(created_at: :asc).limit(500).load
      @phase_timeline = @agent_run.agent_run_phases.load
      @phase_summary = @agent_run.phase_summary(phases: @phase_timeline.to_a)
      @final_provider_record = @agent_run.final_provider_record
      @attempted_providers_by_routing_key = @agent_run.attempted_providers_by_routing_key
    end

    def cancel
      authorize @agent_run
      cancel_agent_run(@agent_run, redirect_path: project_agent_run_path(@project, @agent_run))
    end

    def new
      authorize @project, :run_agent?
      selected_goal = params[:goal].presence || "create_pr"
      @default_provider_identifiers_by_goal = AgentRun::GOALS.index_with do |goal|
        settings_owner&.settings&.default_provider_identifier_for_goal(goal)
      end.compact
      @default_provider_identifier = @default_provider_identifiers_by_goal[selected_goal]
      @available_run_provider_options = available_run_provider_options
      @marketplace_entries = current_account.marketplace_entries.active
        .ordered
        .includes(:current_version)
      @issues = @project.issues
        .issues_only
        .where(github_state: "open")
        .order(github_number: :desc)
        .to_a
      issue_ids = @issues.map(&:id)
      @issues_with_active_runs = @project.agent_runs
        .where(issue_id: issue_ids, goal: "enhance_issue", status: AgentRun::UNFINISHED_STATUSES)
        .distinct
        .pluck(:issue_id)
        .to_set
      @paid_prs_by_issue_id = Issue.open_paid_generated_prs_by_issue_id(
        project: @project, issue_ids: issue_ids
      )
      @issue_enhancement_rounds = @project.agent_runs
        .where(issue_id: issue_ids, goal: "enhance_issue")
        .where.not(status: AgentRun::UNFINISHED_STATUSES)
        .group(:issue_id)
        .count
      @pull_requests = @project.issues
        .pull_requests_only
        .where(github_state: "open")
        .order(github_number: :desc)

      @pull_requests = @pull_requests.to_a
      pr_numbers = @pull_requests.map(&:github_number)
      @prs_with_active_runs = @project.agent_runs
        .where(source_pull_request_number: pr_numbers, status: AgentRun::UNFINISHED_STATUSES)
        .distinct
        .pluck(:source_pull_request_number)
        .to_set

      @pr_priority_tiers = compute_pr_priority_tiers(@pull_requests)
    end

    def create
      authorize @project, :run_agent?

      goal = params[:goal].presence || "create_pr"
      custom_prompt = params[:custom_prompt]&.strip.presence
      issue = resolve_issue
      priority_tier = resolve_priority_tier

      if goal == "review"
        pr_ids = Array(params[:pull_request_ids]).filter_map { |id| Integer(id, exception: false) }.select(&:positive?)
        if pr_ids.empty?
          redirect_to new_project_agent_run_path(@project, goal: goal),
            alert: "Please select at least one pull request to review."
          return
        end

        create_review_runs_and_redirect(
          pr_ids: pr_ids,
          on_error_path: new_project_agent_run_path(@project, goal: goal),
          custom_prompt: custom_prompt,
          goal: goal
        )
      elsif goal == "enhance_issue"
        issue_ids = Array(params[:issue_ids]).filter_map { |id| Integer(id, exception: false) }.select(&:positive?)
        if issue_ids.empty?
          redirect_to new_project_agent_run_path(@project, goal: goal),
            alert: "Please select at least one issue to enhance."
          return
        end

        create_enhance_issue_runs_and_redirect(
          issue_ids: issue_ids,
          on_error_path: new_project_agent_run_path(@project, goal: goal),
          custom_prompt: custom_prompt,
          goal: goal,
          priority_tier: priority_tier
        )
      else
        source_pr_number = resolve_pull_request
        unless issue || custom_prompt || source_pr_number
          redirect_to new_project_agent_run_path(@project, goal: goal),
            alert: "Please select an issue, provide a custom prompt, or select a pull request."
          return
        end

        if goal == "create_pr" && issue && source_pr_number.blank?
          if (paid_pr = issue.associated_paid_pull_request)
            redirect_to new_project_agent_run_path(@project, goal: goal),
              alert: "Paid already opened PR ##{paid_pr.github_number} for this issue. Start a run on the PR instead."
            return
          end
        end

        create_run_and_redirect(
          on_error_path: new_project_agent_run_path(@project, goal: goal),
          issue: issue,
          custom_prompt: custom_prompt,
          source_pull_request_number: source_pr_number,
          goal: goal,
          priority_tier: priority_tier
        )
      end
    end

    def quick_create
      authorize @project, :run_agent?

      issue = resolve_issue
      source_pr_number = resolve_pull_request

      unless issue || source_pr_number
        redirect_to project_path(@project),
          alert: "Please select an issue or pull request."
        return
      end

      if (paid_pr = issue&.associated_paid_pull_request)
        redirect_to project_path(@project),
          alert: "Paid already opened PR ##{paid_pr.github_number} for this issue. Quick run on the PR instead."
        return
      end

      create_run_and_redirect(
        on_error_path: project_path(@project),
        issue: issue,
        provider_identifier: settings_owner&.settings&.default_provider_identifier_for_goal("create_pr"),
        goal: "create_pr",
        source_pull_request_number: source_pr_number
      )
    end

    def bump_priority
      authorize @project, :run_agent?

      pr = resolve_pull_request_record
      unless pr
        redirect_to project_path(@project), alert: "Please select a pull request."
        return
      end

      runs = @project.agent_runs
        .where(source_pull_request_number: pr.github_number, trigger_type: "automatic")
        .where(status: "queued", temporal_workflow_id: nil)

      affected = runs.update_all(trigger_type: "manual", updated_at: Time.current)

      if affected.zero?
        redirect_to project_path(@project), alert: "No queued auto-continue runs for this pull request."
        return
      end

      @project.broadcast_pull_requests_update
      ProcessRunQueueJob.perform_later

      redirect_to project_path(@project), notice: "Priority bumped for PR ##{pr.github_number}."
    end

    def toggle_auto_continue_pause
      authorize @project, :run_agent?

      pr = resolve_pull_request_record
      unless pr
        redirect_to project_path(@project), alert: "Please select a pull request."
        return
      end

      pr.update!(auto_continue_paused: !pr.auto_continue_paused)

      if pr.auto_continue_paused?
        @project.agent_runs
          .where(source_pull_request_number: pr.github_number, trigger_type: "automatic", status: "queued")
          .find_each do |run|
            run.with_lock do
              next unless run.status == "queued"
              run.cancel!
            end
          end

        redirect_to project_path(@project), notice: "Auto-continue paused for PR ##{pr.github_number}."
      else
        result = enqueue_resume_run(pr)
        notice = case result
        when :enqueued
          "Auto-continue resumed for PR ##{pr.github_number}. An agent run has been enqueued."
        when :already_active
          "Auto-continue resumed for PR ##{pr.github_number}. An agent run is already queued or in progress."
        else
          "Auto-continue resumed for PR ##{pr.github_number}. A new agent run will be enqueued when a provider is available."
        end
        redirect_to project_path(@project), notice: notice
      end
    end

    def diagnose_error
      authorize @agent_run

      unless @agent_run.finished?
        redirect_to project_agent_run_path(@project, @agent_run),
          alert: "Only finished runs can be diagnosed."
        return
      end

      unless @agent_run.error_message.present?
        redirect_to project_agent_run_path(@project, @agent_run),
          alert: "Only runs with errors can be diagnosed."
        return
      end

      @agent_run.with_lock do
        case @agent_run.diagnosis_status
        when "in_progress", "processing"
          redirect_to project_agent_run_path(@project, @agent_run),
            alert: "Diagnosis is already in progress."
          return
        when "completed"
          redirect_to project_agent_run_path(@project, @agent_run),
            notice: "Diagnosis has already been completed."
          return
        end

        @agent_run.update!(diagnosis_status: "in_progress")
      end

      @agent_run.project.broadcast_agent_run_detail_update(@agent_run)
      DiagnoseErrorJob.perform_later(@agent_run.id)

      redirect_to project_agent_run_path(@project, @agent_run),
        notice: "Error diagnosis started. You'll see the result shortly."
    end

    def resume
      authorize @agent_run
      redirect_target = safe_return_target || project_agent_run_path(@project, @agent_run)

      unless @agent_run.paused?
        redirect_to redirect_target,
          alert: "Only paused runs can be resumed."
        return
      end

      begin
        cancel_in_flight_execution_for_resume!
      rescue StandardError => e
        Rails.logger.error(
          message: "agent_execution.resume_cancel_failed",
          agent_run_id: @agent_run.id,
          error_class: e.class.name,
          error_message: e.message
        )
        redirect_to redirect_target,
          alert: "Unable to resume until the previous execution is cancelled. Please try again."
        return
      end

      resumed = @agent_run.resume!(decision_point: "manual_resume")
      unless resumed
        redirect_to redirect_target,
          alert: "The agent run state changed and could not be resumed."
        return
      end

      ProcessRunQueueJob.perform_later

      redirect_to redirect_target,
        notice: "Agent run resumed and re-queued."
    rescue ActiveRecord::RecordNotUnique
      redirect_to redirect_target,
        alert: "Another agent run is already queued or in progress for this target."
    end

    def terminate
      authorize @agent_run

      terminated = false

      @agent_run.with_lock do
        @agent_run.reload

        unless @agent_run.paused?
          redirect_to project_agent_run_path(@project, @agent_run),
            alert: "The agent run state changed and could not be terminated."
          return
        end

        guardrail_type = termination_guardrail_type(@agent_run)
        @agent_run.update!(
          status: "cancelled",
          completed_at: Time.current,
          paused_at: nil,
          error_message: "Terminated after guardrail violation: #{guardrail_type}",
          duration_seconds: @agent_run.duration
        )
        terminated = true
      end

      if terminated
        begin
          AgentRuns::Cancel.call(agent_run: @agent_run, skip_status_update: true)
        rescue StandardError => e
          Rails.logger.error(
            message: "agent_execution.terminate_cleanup_failed",
            agent_run_id: @agent_run.id,
            error_class: e.class.name,
            error_message: e.message
          )
        end
      end

      redirect_to project_agent_run_path(@project, @agent_run),
        notice: "Agent run terminated."
    end

    def retry
      authorize @agent_run

      unless @agent_run.finished?
        redirect_to project_agent_run_path(@project, @agent_run),
          alert: "Only finished runs can be retried."
        return
      end

      agent_type = retry_agent_type_for(@agent_run)
      if agent_type.nil?
        redirect_to project_agent_run_path(@project, @agent_run),
          alert: "The selected provider is not available for retries."
        return
      end

      retry_provider = if params[:provider].present?
        configured_provider_for_retry(params[:provider])
      else
        @agent_run.provider || current_retry_provider_for(@agent_run)
      end

      new_run = ActiveRecord::Base.transaction do
        created_run = AgentRun.create!(
          project: @project,
          issue: @agent_run.issue,
          provider: retry_provider,
          agent_type: agent_type,
          custom_prompt: prompt_for_retry(@agent_run),
          source_pull_request_number: @agent_run.source_pull_request_number,
          goal: @agent_run.goal,
          trigger_type: "manual",
          status: "queued"
        )
        copy_marketplace_attachments(source_run: @agent_run, target_run: created_run)

        @agent_run.retry!(
          decision_point: "manual_retry",
          signals: {
            selected_agent_type: agent_type,
            selected_provider: retry_provider&.routing_key || retry_provider&.provider_key
          },
          result: { new_agent_run_id: created_run.id }
        )

        created_run
      end

      ProcessRunQueueJob.perform_later

      redirect_to project_agent_run_path(@project, new_run),
        notice: "Agent run queued as a retry of run ##{@agent_run.id}."
    rescue ActiveRecord::RecordNotUnique => e
      log_failed_retry_decision(
        decision_point: "manual_retry",
        signals: {
          selected_agent_type: agent_type,
          selected_provider: retry_provider&.routing_key || retry_provider&.provider_key
        },
        error: e
      )
      alert = if (e.cause&.message || e.message).include?("proxy_token")
        "An unexpected error occurred. Please try again."
      else
        "An agent run is already queued or in progress for this issue."
      end
      redirect_to project_agent_run_path(@project, @agent_run), alert: alert
    end

    def refresh_auth
      authorize @agent_run

      unless @agent_run.auth_expired?
        redirect_to project_agent_run_path(@project, @agent_run),
          alert: "Only runs with expired authentication can be re-authenticated."
        return
      end

      token = (params[:auth_token].presence || params[:auth_code])&.strip
      if token.blank?
        redirect_to project_agent_run_path(@project, @agent_run),
          alert: "Please provide an authentication token."
        return
      end

      provider = @agent_run.auth_provider.presence&.to_sym
      if provider.nil?
        Rails.logger.error(
          message: "agent_execution.missing_auth_provider",
          agent_run_id: @agent_run.id,
          agent_type: @agent_run.agent_type
        )
        redirect_to project_agent_run_path(@project, @agent_run),
          alert: "Unable to determine authentication provider for this run."
        return
      end

      unless AgentHarness.respond_to?(:refresh_auth)
        Rails.logger.error(
          message: "agent_execution.refresh_auth_unsupported",
          agent_run_id: @agent_run.id
        )
        redirect_to project_agent_run_path(@project, @agent_run),
          alert: "Re-authentication is not supported for this agent."
        return
      end

      AgentHarness.refresh_auth(provider, token: token)

      new_run = ActiveRecord::Base.transaction do
        created_run = AgentRun.create!(
          project: @project,
          issue: @agent_run.issue,
          provider: @agent_run.provider,
          agent_type: @agent_run.agent_type,
          custom_prompt: prompt_for_retry(@agent_run),
          source_pull_request_number: @agent_run.source_pull_request_number,
          goal: @agent_run.goal,
          trigger_type: "manual",
          status: "queued"
        )
        copy_marketplace_attachments(source_run: @agent_run, target_run: created_run)

        @agent_run.retry!(
          decision_point: "refresh_auth_retry",
          signals: { auth_provider: provider.to_s },
          result: { new_agent_run_id: created_run.id }
        )

        created_run
      end
      ProcessRunQueueJob.perform_later

      redirect_to project_agent_run_path(@project, new_run),
        notice: "Authentication refreshed. Agent run queued for retry."
    # Catch all harness errors (including AuthenticationError, which is a
    # subclass of Error) so this works even when the shim hasn't loaded yet.
    rescue AgentHarness::Error => e
      log_failed_retry_decision(
        decision_point: "refresh_auth_retry",
        signals: { auth_provider: provider&.to_s },
        error: e
      )
      Rails.logger.error(
        message: "agent_execution.refresh_auth_failed",
        agent_run_id: @agent_run.id,
        error_class: e.class.name,
        error_message: e.message
      )
      redirect_to project_agent_run_path(@project, @agent_run),
        alert: "Re-authentication failed: #{e.message}"
    rescue NotImplementedError => e
      log_failed_retry_decision(
        decision_point: "refresh_auth_retry",
        signals: { auth_provider: @agent_run.auth_provider },
        error: e
      )
      Rails.logger.error(
        message: "agent_execution.refresh_auth_unavailable",
        agent_run_id: @agent_run.id,
        provider: @agent_run.auth_provider,
        error_class: e.class.name,
        error_message: e.message
      )
      redirect_to project_agent_run_path(@project, @agent_run),
        alert: "Re-authentication is not supported for this provider."
    rescue ActiveRecord::RecordNotUnique => e
      log_failed_retry_decision(
        decision_point: "refresh_auth_retry",
        signals: { auth_provider: @agent_run.auth_provider },
        error: e
      )
      alert = if (e.cause&.message || e.message).include?("proxy_token")
        "An unexpected error occurred. Please try again."
      else
        "An agent run is already queued or in progress for this issue."
      end
      redirect_to project_agent_run_path(@project, @agent_run), alert: alert
    end

    private

    # Clear auto-generated prompts on retry so PreparePrPromptActivity rebuilds
    # them with current state (service containers, CI status, review threads).
    # Any prepare_pr_prompt phase in the "prompt" phase group—completed or
    # failed—means the prompt was auto-generated, so we clear it regardless of
    # phase status. User-supplied prompts (no such prepare_pr_prompt phase) are
    # preserved as-is.
    def prompt_for_retry(agent_run)
      if agent_run.agent_run_phases.exists?(phase_key: "prepare_pr_prompt", phase_group: "prompt")
        nil
      else
        agent_run.custom_prompt
      end
    end

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def set_agent_run
      @agent_run = @project.agent_runs.find(params[:id])
    end

    def resolve_issue
      return nil if params[:issue_id].blank?

      @project.issues.find(params[:issue_id])
    end

    def resolve_priority_tier
      tier = params[:priority_tier].presence
      tier if Project::PRIORITY_TIERS.include?(tier)
    end

    def apply_priority_label(issue, tier)
      label_name = @project.priority_label_for(tier)
      return if label_name.blank?

      current_labels = Array(issue.labels)
      return if current_labels.include?(label_name)

      stale_priority_labels = current_labels & @project.priority_label_names
      new_labels = (current_labels - stale_priority_labels) + [ label_name ]
      issue.update!(labels: new_labels)

      [ label_name, stale_priority_labels ]
    end

    def sync_priority_label_to_github(issue, label_name, stale_labels)
      return unless issue.github_number

      client = @project.github_token.client
      stale_labels.each do |old_label|
        client.remove_label_from_issue(@project.full_name, issue.github_number, old_label)
      rescue GithubClient::Error => e
        Rails.logger.warn(
          message: "agent_execution.remove_priority_label_failed",
          issue_id: issue.id,
          label: old_label,
          error: e.message
        )
      end
      client.add_labels_to_issue(@project.full_name, issue.github_number, [ label_name ])
    rescue GithubClient::Error => e
      Rails.logger.warn(
        message: "agent_execution.sync_priority_label_failed",
        issue_id: issue.id,
        label: label_name,
        error: e.message
      )
    end

    def resolve_pull_request
      return nil if params[:pull_request_id].blank?

      pr = @project.issues.pull_requests_only.find(params[:pull_request_id])
      pr.github_number
    end

    def resolve_pull_request_record
      return nil if params[:pull_request_id].blank?

      @project.issues.pull_requests_only.find_by(id: params[:pull_request_id])
    end

    def cancel_in_flight_execution_for_resume!
      return if @agent_run.temporal_workflow_id.blank?

      AgentRuns::Cancel.call(agent_run: @agent_run, skip_status_update: true)
      @agent_run.reload
    end

    def create_agent_run(issue: nil, custom_prompt: nil, source_pull_request_number: nil, agent_type: nil, provider_identifier: nil, goal: nil, trigger_type: "manual", priority_tier: nil)
      goal ||= params[:goal].presence || "create_pr"
      goal = "create_pr" unless AgentRun::GOALS.include?(goal)

      requested_agent_type = agent_type || params[:agent_type].presence
      requested_provider_identifier = provider_identifier || params[:provider].presence
      resolved_provider = resolve_provider_selection(
        requested_agent_type: requested_agent_type,
        requested_provider_identifier: requested_provider_identifier,
        goal: goal
      )
      raise NoRunnableProviderError, "No runnable provider could be resolved for this project." unless resolved_provider

      resolved_agent_type = provider_key_to_agent_type(resolved_provider.provider_key)

      ActiveRecord::Base.transaction do
        agent_run = AgentRun.create!(
          project: @project,
          issue: issue,
          provider: resolved_provider,
          agent_type: resolved_agent_type,
          custom_prompt: custom_prompt,
          source_pull_request_number: source_pull_request_number,
          goal: goal,
          trigger_type: trigger_type,
          status: "queued",
          priority_tier: priority_tier
        )
        attach_marketplace_entries(agent_run:)
        agent_run
      end
    end

    def attach_marketplace_entries(agent_run:)
      manual_entry_ids = params.permit(marketplace_entry_ids: []).fetch(:marketplace_entry_ids, nil)
      account_auto_attach_required = marketplace_auto_attach_required_for_current_account?

      MarketplaceEntries::AttachToRun.call(
        agent_run:,
        manual_entry_ids: manual_entry_ids,
        auto_attach_enabled: marketplace_auto_attach_enabled_for_current_user?,
        account_auto_attach_required: account_auto_attach_required
      )
    rescue => e
      Rails.logger.warn(
        message: "agent_execution.marketplace_attachment_failed",
        agent_run_id: agent_run.id,
        error_class: e.class.name,
        error: e.message
      )
      raise if account_auto_attach_required || Array(manual_entry_ids).any?
      raise unless ignorable_marketplace_attachment_error?(e)
    end

    def copy_marketplace_attachments(source_run:, target_run:)
      attachments = source_run.agent_run_marketplace_entries.includes(:marketplace_entry, :marketplace_entry_version).ordered.to_a
      return if attachments.empty?

      attachments.each do |attachment|
        target_run.agent_run_marketplace_entries.create!(
          marketplace_entry: attachment.marketplace_entry,
          marketplace_entry_version: attachment.marketplace_entry_version,
          attachment_source: attachment.attachment_source,
          position: attachment.position,
          selection_reason: attachment.selection_reason,
          rendered_format: attachment.rendered_format,
          rendered_payload: attachment.rendered_payload.deep_dup
        )
      end

      MarketplaceEntries::RerenderForRun.call(agent_run: target_run)
    end

    def marketplace_auto_attach_enabled_for_current_user?
      current_user&.settings&.marketplace_auto_attach_enabled? || false
    end

    def marketplace_auto_attach_required_for_current_account?
      current_account&.tenant_setting&.marketplace_auto_attach_required? || false
    end

    def ignorable_marketplace_attachment_error?(error)
      error.is_a?(ActiveRecord::RecordNotFound) || error.is_a?(ActiveRecord::RecordInvalid)
    end

    def enqueue_resume_run(pr)
      create_agent_run(
        source_pull_request_number: pr.github_number,
        provider_identifier: settings_owner&.settings&.default_provider_identifier_for_goal("create_pr"),
        goal: "create_pr",
        trigger_type: "automatic"
      )
      ProcessRunQueueJob.perform_later
      :enqueued
    rescue NoRunnableProviderError => e
      Rails.logger.warn(
        message: "agent_execution.resume_run_skipped",
        reason: e.message,
        pull_request_number: pr.github_number
      )
      :no_provider
    rescue ActiveRecord::RecordNotUnique => e
      constraint_message = e.cause&.message || e.message
      if constraint_message.include?("idx_agent_runs_unique_active_pr")
        Rails.logger.warn(
          message: "agent_execution.resume_run_skipped",
          reason: "run_already_queued",
          pull_request_number: pr.github_number
        )
        :already_active
      else
        raise
      end
    end

    def create_run_and_redirect(on_error_path:, **attrs)
      budget_result = CostBudgets::Check.call(@project)
      unless budget_result[:allowed]
        Rails.logger.info(
          message: "agent_execution.budget_check_blocked",
          project_id: @project.id,
          reason: budget_result[:reason]
        )
        redirect_to on_error_path, alert: "Your project's AI budget has been reached. Please adjust your budget settings or try again later."
        return
      end

      issue = attrs[:issue]
      priority_tier = attrs[:priority_tier]

      github_sync_args = nil
      ActiveRecord::Base.transaction do
        create_agent_run(**attrs)
        github_sync_args = apply_priority_label(issue, priority_tier) if issue && priority_tier
      end

      if github_sync_args
        label_name, stale_labels = github_sync_args
        sync_priority_label_to_github(issue, label_name, stale_labels)
      end

      ProcessRunQueueJob.perform_later

      capacity_user = settings_owner || current_user
      notice = if AgentRun.has_run_capacity?(user: capacity_user) && AgentRun.queued.count <= 1
        "Agent run created and will start momentarily."
      else
        "Agent run queued. It will start automatically when a slot opens."
      end

      redirect_to project_path(@project), notice: notice
    rescue NoRunnableProviderError => e
      redirect_to on_error_path, alert: e.message
    rescue ActiveRecord::RecordInvalid => e
      redirect_to on_error_path, alert: e.message
    rescue ActiveRecord::RecordNotUnique => e
      alert = if (e.cause&.message || e.message).include?("proxy_token")
        "An unexpected error occurred. Please try again."
      else
        "An agent run is already queued or in progress."
      end
      redirect_to on_error_path, alert: alert
    end

    def provider_key_to_agent_type(provider_key)
      Provider.agent_type_for(provider_key)
    end

    def agent_type_to_provider_key(agent_type)
      Provider.provider_key_for_agent_type(agent_type)
    end

    def managed_provider_key?(provider_key)
      Provider.supported_provider_key?(provider_key)
    end

    def retry_provider_options_for(agent_run)
      current_provider = current_retry_provider_for(agent_run)

      enabled_retry_provider_entries.filter_map do |identifier, provider|
        agent_type = provider_key_to_agent_type(provider.provider_key)
        next unless AgentRun::AGENT_TYPES.include?(agent_type)

        {
          provider_key: identifier,
          agent_type: agent_type,
          label: provider.display_name,
          current: current_provider.present? && provider.id == current_provider.id
        }
      end
    end

    def current_retry_provider_for(agent_run)
      return agent_run.provider if agent_run.provider

      provider_key = agent_type_to_provider_key(agent_run.agent_type)
      return unless provider_key

      Provider.for_identifier(settings_owner, provider_key)
    end

    def retry_agent_type_for(agent_run)
      requested_provider_identifier = params[:provider].presence
      requested_agent_type = params[:agent_type].presence

      return agent_run.agent_type if requested_provider_identifier.blank? && requested_agent_type.blank?

      if requested_provider_identifier.present?
        provider = configured_provider_for_retry(requested_provider_identifier)
        return nil unless provider

        requested_agent_type = provider_key_to_agent_type(provider.provider_key)
      end
      return nil unless retry_agent_type_allowed?(requested_agent_type)

      requested_agent_type
    end

    def retry_agent_type_allowed?(agent_type)
      return false unless AgentRun::AGENT_TYPES.include?(agent_type)

      provider_key = agent_type_to_provider_key(agent_type)
      return true unless managed_provider_key?(provider_key)

      enabled_retry_providers.any? { |provider| provider.provider_key == provider_key }
    end

    def log_failed_retry_decision(decision_point:, signals:, error:)
      OrchestrationDecision.record(
        project: @project,
        issue: @agent_run.issue,
        agent_run: @agent_run,
        decision_point: decision_point,
        action: "retry",
        status: "failed",
        signals: signals,
        result: {
          error_class: error.class.name,
          error_message: error.message
        }
      )
    end

    def resolve_provider_selection(requested_agent_type:, requested_provider_identifier:, goal:)
      owner = settings_owner
      return unless owner

      configured_identifiers = UserSetting.enabled_agent_providers(owner, identifiers: true)
      priority_identifiers = owner.settings.provider_priority_for_goal(goal, identifiers: true)
      default_identifier = priority_identifiers.first

      if requested_provider_identifier.present?
        provider = configured_provider_for_retry(requested_provider_identifier)
        return provider if provider
      end

      if requested_agent_type.present? && AgentRun::AGENT_TYPES.include?(requested_agent_type)
        requested_provider_key = agent_type_to_provider_key(requested_agent_type)
        matches = enabled_retry_providers.select { |entry| entry.provider_key == requested_provider_key }
        provider = matches.find(&:subscription?) || matches.first
        return provider if provider
      end

      selected_identifier = if configured_identifiers.include?(default_identifier)
        default_identifier
      else
        priority_identifiers.first || configured_identifiers.first
      end

      provider_for_identifier(selected_identifier) || Provider.ensure_default_for(owner)
    end

    def provider_for_identifier(identifier)
      Provider.for_identifier(settings_owner, identifier)
    end

    # Returns [identifier, provider] pairs for all enabled agent providers,
    # bulk-loaded in two queries to avoid N+1.
    def enabled_retry_provider_entries
      @enabled_retry_provider_entries ||= begin
        owner = settings_owner
        unless owner
          []
        else
          identifiers = UserSetting.enabled_agent_providers(owner, identifiers: true)

          routing_ids = []
          plain_keys = []
          identifiers.each do |id|
            if Provider.routing_key?(id)
              routing_ids << Provider.id_from_routing_key(id)
            else
              plain_keys << id
            end
          end

          providers_by_id = owner.providers.kept_only.where(id: routing_ids).index_by(&:id)
          providers_by_key = owner.providers.kept_only.where(provider_key: plain_keys).ordered
            .group_by(&:provider_key)

          identifiers.filter_map do |identifier|
            provider = if Provider.routing_key?(identifier)
              providers_by_id[Provider.id_from_routing_key(identifier)]
            else
              group = providers_by_key[identifier]
              next unless group
              # Prefer subscription entry, matching Provider.for_identifier behavior
              group.find(&:subscription?) || group.first
            end
            next unless provider

            [ identifier, provider ]
          end
        end
      end
    end

    def settings_owner
      @settings_owner ||= @project.effective_owner
    end

    def enabled_retry_providers
      @enabled_retry_providers ||= enabled_retry_provider_entries.map(&:last)
    end

    def configured_provider_for_retry(identifier)
      return if identifier.blank?

      identifier = identifier.to_s
      if Provider.routing_key?(identifier)
        enabled_retry_providers.find { |entry| entry.routing_key == identifier }
      else
        # Prefer subscription entry when multiple providers share the same key,
        # matching Provider.for_identifier backward-compat behavior.
        matches = enabled_retry_providers.select { |entry| entry.provider_key == identifier }
        matches.find(&:subscription?) || matches.first
      end
    end

    def termination_guardrail_type(agent_run)
      agent_run.guardrail_violation_type.presence ||
        agent_run.guardrail_context&.dig("violation_type").presence ||
        "unknown"
    end

    def safe_return_target
      url_from(params[:return_to])
    end

    def create_review_runs_and_redirect(pr_ids:, on_error_path:, custom_prompt:, goal:)
      # Soft gate: budget is re-checked at execution time in ProcessRunQueueJob#start_claimed_run,
      # so over-queuing is caught before any spend occurs.
      budget_result = CostBudgets::Check.call(@project)
      unless budget_result[:allowed]
        redirect_to on_error_path, alert: "Your project's AI budget has been reached. Please adjust your budget settings or try again later."
        return
      end

      prs = @project.issues.pull_requests_only.where(id: pr_ids)
      if prs.empty?
        redirect_to on_error_path, alert: "None of the selected pull requests could be found."
        return
      end

      # Filter out PRs that already have active (unfinished) runs server-side,
      # since the client-side disabled checkbox can be bypassed or hit by a race.
      active_pr_numbers = @project.agent_runs
        .where(source_pull_request_number: prs.map(&:github_number), status: AgentRun::UNFINISHED_STATUSES)
        .pluck(:source_pull_request_number)
      prs = prs.where.not(github_number: active_pr_numbers) if active_pr_numbers.any?
      if prs.empty?
        redirect_to on_error_path, alert: "All selected pull requests already have active runs."
        return
      end

      ActiveRecord::Base.transaction do
        prs.each do |pr|
          create_agent_run(
            custom_prompt: custom_prompt,
            source_pull_request_number: pr.github_number,
            goal: goal
          )
        end
      end
      ProcessRunQueueJob.perform_later

      notice = if prs.size == 1
        "Agent run queued for PR review."
      else
        "#{prs.size} agent runs queued for PR review."
      end
      redirect_to project_path(@project), notice: notice
    rescue NoRunnableProviderError => e
      redirect_to on_error_path, alert: e.message
    rescue ActiveRecord::RecordNotUnique
      # Only proxy_token has a unique index; duplicate PR runs are caught
      # server-side above (active_pr_numbers filter) rather than by a DB constraint.
      redirect_to on_error_path, alert: "An unexpected error occurred. Please try again."
    end

    def create_enhance_issue_runs_and_redirect(issue_ids:, on_error_path:, custom_prompt:, goal:, priority_tier:)
      budget_result = CostBudgets::Check.call(@project)
      unless budget_result[:allowed]
        redirect_to on_error_path, alert: "Your project's AI budget has been reached. Please adjust your budget settings or try again later."
        return
      end

      issues = @project.issues.issues_only.where(id: issue_ids)
      if issues.empty?
        redirect_to on_error_path, alert: "None of the selected issues could be found."
        return
      end

      # Filter out issues that already have active (unfinished) enhance_issue runs
      active_issue_ids = @project.agent_runs
        .where(issue_id: issues.map(&:id), goal: "enhance_issue", status: AgentRun::UNFINISHED_STATUSES)
        .pluck(:issue_id)
      issues = issues.where.not(id: active_issue_ids) if active_issue_ids.any?
      if issues.empty?
        redirect_to on_error_path, alert: "All selected issues already have active enhancement runs."
        return
      end

      github_sync_args_list = []
      ActiveRecord::Base.transaction do
        issues.each do |issue|
          create_agent_run(
            issue: issue,
            custom_prompt: custom_prompt,
            goal: goal,
            priority_tier: priority_tier
          )
          sync_args = apply_priority_label(issue, priority_tier) if priority_tier
          github_sync_args_list << [ issue, sync_args ] if sync_args
        end
      end

      github_sync_args_list.each do |issue, (label_name, stale_labels)|
        sync_priority_label_to_github(issue, label_name, stale_labels)
      end

      ProcessRunQueueJob.perform_later

      notice = if issues.size == 1
        "Agent run queued for issue enhancement."
      else
        "#{issues.size} agent runs queued for issue enhancement."
      end
      redirect_to project_path(@project), notice: notice
    rescue NoRunnableProviderError => e
      redirect_to on_error_path, alert: e.message
    rescue ActiveRecord::RecordNotUnique
      redirect_to on_error_path, alert: "An unexpected error occurred. Please try again."
    end

    def compute_pr_priority_tiers(pull_requests)
      priority_labels = @project.effective_priority_labels
      pull_requests.each_with_object({}) do |pr, hash|
        tier = Project::PRIORITY_TIERS.find do |t|
          label_name = priority_labels[t]
          label_name && pr.labels.include?(label_name)
        end
        hash[pr.id] = tier
      end
    end

    def available_run_provider_options
      enabled_retry_provider_entries.map do |identifier, provider|
        [ provider.display_name, identifier ]
      end
    end
  end
end
