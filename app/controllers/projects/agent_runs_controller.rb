# frozen_string_literal: true

module Projects
  class AgentRunsController < ApplicationController
    include AgentRunCancellable
    include AuditLogging

    NoRunnableRunnerError = Class.new(StandardError)
    InvalidDockerHostSelectionError = Containers::ResolveHostForRun::InvalidDockerHostSelectionError

    before_action :set_project
    before_action :set_agent_run, only: [ :show, :cancel, :retry, :refresh_auth, :diagnose_error, :resume, :terminate, :provenance ]

    def index
      authorize @project, :show?
      base_scope = @project.agent_runs.excluding_synthetic.includes(:runner, project: [ :created_by, :account ], issue: :project)
      @q = base_scope.ransack(params[:q])
      @q.sorts = "created_at desc" if @q.sorts.empty?
      @pagy, @agent_runs = pagy(@q.result)
      AgentRun.preload_final_runner_records(@agent_runs)
      AgentRun.preload_source_pull_requests(@agent_runs)
      AgentRun.preload_created_issue_records(@agent_runs)
      cache_key = AgentRun.runner_options_cache_key_for(account_id: @project.account_id, project_id: @project.id)
      @runner_options = base_scope.distinct_effective_runner_options(account_id: @project.account_id, cache_key: cache_key)
    end

    # @spec EXECUTION-ISOLATION-005
    def show
      authorize @agent_run
      @retry_runner_options = retry_runner_options_for(@agent_run)
      @retry_docker_host_options = available_docker_host_options(
        include_inherit: true,
        runner: @agent_run.runner || current_retry_runner_for(@agent_run)
      )
      @quality_metrics = @agent_run.quality_metrics.with_composite_score.load
      @logs = @agent_run.agent_run_logs.order(created_at: :asc).limit(500).load
      @phase_timeline = @agent_run.agent_run_phases.load
      @phase_summary = @agent_run.phase_summary(phases: @phase_timeline.to_a)
      @final_runner_record = @agent_run.final_runner_record
      @attempted_runners_by_routing_key = @agent_run.attempted_runners_by_routing_key
      @egress_policy_snapshot = @agent_run.egress_policy_snapshot
      egress_audit_events = @agent_run.egress_security_events.audit_visible
      @egress_security_events = egress_audit_events.recent.limit(50).load
      @egress_denied_event_count = egress_audit_events.count
    end

    def provenance
      authorize @agent_run, :show?

      @provenance = RunProvenanceBuilder.new(@agent_run).build

      respond_to do |format|
        format.html
        format.json { render json: @provenance }
      end
    end

    # Returns docker host select options filtered by the supplied runner
    # identifier. The new and retry forms call this on runner change so the
    # visible host list stays in sync with runner compatibility, since the
    # server is the authoritative source for credential-aware eligibility.
    def docker_host_options
      authorize @project, :run_agent?
      runner = runner_for_docker_host_param
      placement_context = docker_host_selection_context(runner: runner)

      render json: {
        runner_identifier: params[:runner].to_s.presence,
        selected_host_identifier: current_eligible_host_identifier(eligible_hosts: placement_context[:eligible_hosts]),
        options: available_docker_host_options(
          include_inherit: true,
          eligible_hosts: placement_context[:eligible_hosts]
        )
      }
    end

    def cancel
      authorize @agent_run
      cancel_agent_run(@agent_run, redirect_path: project_agent_run_path(@project, @agent_run))
    end

    def new
      authorize @project, :run_agent?
      selected_goal = params[:goal].presence || "create_pr"
      @default_runner_identifiers_by_goal = AgentRun::GOALS.index_with do |goal|
        settings_owner&.settings&.default_runner_identifier_for_goal(goal)
      end.compact
      @default_runner_identifier = @default_runner_identifiers_by_goal[selected_goal]
      @available_run_runner_options = available_run_runner_options
      @available_docker_host_options = available_docker_host_options(
        include_inherit: true,
        runner: default_runner_for_goal(selected_goal)
      )
      @marketplace_entries = marketplace_entries_for_new_run.to_a
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
      blocked_by_issue_ids = resolve_blocked_by_issue_ids
      plan_docs = resolve_plan_docs

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
      elsif goal == "create_feature"
        feature_description = params[:feature_description]&.strip.presence
        unless feature_description
          redirect_to new_project_agent_run_path(@project, goal: goal),
            alert: "Please provide a feature description."
          return
        end
        create_feature_run_and_redirect(
          feature_description: feature_description,
          on_error_path: new_project_agent_run_path(@project, goal: goal),
          priority_tier: priority_tier
        )
      else
        source_pr_number = resolve_pull_request
        unless issue || custom_prompt || source_pr_number || (goal == "lid_planning" && plan_docs.present?)
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
          priority_tier: priority_tier,
          blocked_by_issue_ids: blocked_by_issue_ids,
          plan_docs: plan_docs
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
        runner_identifier: settings_owner&.settings&.default_runner_identifier_for_goal("create_pr"),
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

    # @spec PR-ESCALATION-014 @spec PR-ESCALATION-015 @spec PR-ESCALATION-017
    def unblock_escalation
      authorize @project, :run_agent?

      pr = resolve_pull_request_record
      unless pr
        redirect_to dashboard_path, alert: "Please select a pull request."
        return
      end

      result = PullRequests::Unblock.call(pull_request: pr, actor: current_user)
      @project.broadcast_pull_requests_update if result.success?

      redirect_to dashboard_path, **unblock_flash(result, pr)
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
          "Auto-continue resumed for PR ##{pr.github_number}. A new agent run will be enqueued when a runner is available."
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

      audit_event("agent_run.resumed", metadata: { agent_run_id: @agent_run.id, project_name: @project.name })

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
        audit_event("agent_run.terminated", metadata: { agent_run_id: @agent_run.id, project_name: @project.name })
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
          alert: "The selected runner is not available for retries."
        return
      end

      retry_runner = if params[:runner].present?
        configured_runner_for_retry(params[:runner])
      else
        @agent_run.runner || current_retry_runner_for(@agent_run)
      end

      new_run = AgentRun.create!(
        project: @project,
        issue: @agent_run.issue,
        initiating_user: current_user,
        runner: retry_runner,
        agent_type: agent_type,
        custom_prompt: prompt_for_retry(@agent_run),
        source_pull_request_number: @agent_run.source_pull_request_number,
        goal: @agent_run.goal,
        **resolved_container_host_attributes(runner: retry_runner),
        trigger_type: "manual",
        status: "queued"
      )

      @agent_run.retry!(
        decision_point: "manual_retry",
        signals: {
          selected_agent_type: agent_type,
          selected_runner: retry_runner&.routing_key || retry_runner&.runner_key
        },
        result: { new_agent_run_id: new_run.id }
      )

      audit_event("agent_run.retried",
        metadata: { agent_run_id: @agent_run.id, new_agent_run_id: new_run.id, project_name: @project.name })

      ProcessRunQueueJob.perform_later

      redirect_to project_agent_run_path(@project, new_run),
        notice: "Agent run queued as a retry of run ##{@agent_run.id}."
    rescue ActiveRecord::RecordNotUnique => e
      log_failed_retry_decision(
        decision_point: "manual_retry",
        signals: {
          selected_agent_type: agent_type,
          selected_runner: retry_runner&.routing_key || retry_runner&.runner_key
        },
        error: e
      )
      alert = if (e.cause&.message || e.message).include?("proxy_token")
        "An unexpected error occurred. Please try again."
      else
        "An agent run is already queued or in progress for this issue."
      end
      redirect_to project_agent_run_path(@project, @agent_run), alert: alert
    rescue InvalidDockerHostSelectionError => e
      redirect_to project_agent_run_path(@project, @agent_run), alert: e.message
    end

    def refresh_auth
      authorize @agent_run

      unless @agent_run.auth_expired?
        redirect_to project_agent_run_path(@project, @agent_run),
          alert: "Only runs with expired authentication can be re-authenticated."
        return
      end

      token = (request.POST["auth_token"].presence || request.POST["auth_code"])&.strip
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
          alert: "Unable to determine authentication runner for this run."
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

      new_run = AgentRun.create!(
        project: @project,
        issue: @agent_run.issue,
        initiating_user: current_user,
        runner: @agent_run.runner,
        agent_type: @agent_run.agent_type,
        custom_prompt: prompt_for_retry(@agent_run),
        source_pull_request_number: @agent_run.source_pull_request_number,
        goal: @agent_run.goal,
        **resolved_container_host_attributes(runner: @agent_run.runner),
        trigger_type: "manual",
        status: "queued"
      )
      @agent_run.retry!(
        decision_point: "refresh_auth_retry",
        signals: { auth_provider: provider.to_s },
        result: { new_agent_run_id: new_run.id }
      )
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
        alert: "Re-authentication is not supported for this runner."
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
    rescue InvalidDockerHostSelectionError => e
      redirect_to project_agent_run_path(@project, @agent_run), alert: e.message
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

    def resolve_blocked_by_issue_ids
      Array(params[:blocked_by_issue_ids]).filter_map { |id| Integer(id, exception: false) }.select(&:positive?)
    end

    def resolve_plan_docs
      Array(params[:plan_docs]).filter_map do |doc|
        next unless doc.respond_to?(:[])

        name = doc["name"]
        { "name" => name.to_s } if name.present?
      end
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

      client = @project.client
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

    def unblock_flash(result, pull_request)
      if result.success?
        return { notice: "PR ##{pull_request.github_number} unblocked, but auto-continue is still paused for it." } if pull_request.auto_continue_paused?

        return { notice: "PR ##{pull_request.github_number} unblocked. Paid picks it up on the next scan." }
      end

      case result.error
      when :not_open
        { alert: "PR ##{pull_request.github_number} is no longer open." }
      else
        { alert: "PR ##{pull_request.github_number} is not blocked." }
      end
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

    def create_agent_run(issue: nil, custom_prompt: nil, source_pull_request_number: nil, agent_type: nil, runner_identifier: nil, goal: nil, trigger_type: "manual", priority_tier: nil, blocked_by_issue_ids: [], plan_docs: [])
      goal ||= params[:goal].presence || "create_pr"
      goal = "create_pr" unless AgentRun::GOALS.include?(goal)

      requested_agent_type = agent_type || params[:agent_type].presence
      requested_runner_identifier = runner_identifier || params[:runner].presence
      resolved_runner = resolve_runner_selection(
        requested_agent_type: requested_agent_type,
        requested_runner_identifier: requested_runner_identifier,
        goal: goal
      )
      raise NoRunnableRunnerError, "No runnable runner could be resolved for this project." unless resolved_runner

      resolved_agent_type = runner_key_to_agent_type(resolved_runner.runner_key)

      host_attributes = resolved_container_host_attributes(runner: resolved_runner)
      external_metadata = host_attributes[:external_metadata] || {}
      external_metadata = external_metadata.merge("plan_docs" => plan_docs) if plan_docs.any?

      ActiveRecord::Base.transaction do
        agent_run = AgentRun.create!(
          project: @project,
          issue: issue,
          initiating_user: current_user,
          runner: resolved_runner,
          agent_type: resolved_agent_type,
          custom_prompt: custom_prompt,
          source_pull_request_number: source_pull_request_number,
          goal: goal,
          container_host: host_attributes[:container_host],
          external_metadata: external_metadata,
          trigger_type: trigger_type,
          status: "queued",
          priority_tier: priority_tier,
          blocked_by_issue_ids: blocked_by_issue_ids
        )
        attach_marketplace_entries(agent_run: agent_run)
        agent_run
      end
    end

    def attach_marketplace_entries(agent_run:)
      manual_entry_ids = params.permit(marketplace_entry_ids: []).fetch(:marketplace_entry_ids, nil)
      account_auto_attach_required = marketplace_auto_attach_required_for_current_account?

      MarketplaceEntries::AttachToRun.call(
        agent_run: agent_run,
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
      raise unless e.is_a?(ActiveRecord::RecordNotFound)
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
          rendered_payload: attachment.rendered_payload
        )
      end

      MarketplaceEntries::RerenderForRun.call(agent_run: target_run)
    end

    def marketplace_auto_attach_enabled_for_current_user?
      !!current_user.settings&.marketplace_auto_attach_enabled?
    end

    def marketplace_auto_attach_required_for_current_account?
      !!@project.account.tenant_setting&.marketplace_auto_attach_required?
    end

    def marketplace_entries_for_new_run
      @project.account.marketplace_entries.active.where.not(current_version_id: nil).ordered.includes(:current_version)
    end

    def enqueue_resume_run(pr)
      create_agent_run(
        source_pull_request_number: pr.github_number,
        runner_identifier: settings_owner&.settings&.default_runner_identifier_for_goal("create_pr"),
        goal: "create_pr",
        trigger_type: AgentRun.retry_trigger_type_for(
          project: @project,
          source_pull_request_number: pr.github_number,
          goal: "create_pr"
        )
      )
      ProcessRunQueueJob.perform_later
      :enqueued
    rescue NoRunnableRunnerError => e
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
      goal = attrs[:goal]
      priority_tier = attrs[:priority_tier]

      agent_run = nil
      github_sync_args = nil
      ActiveRecord::Base.transaction do
        agent_run = create_agent_run(**attrs)
        github_sync_args = apply_priority_label(issue, priority_tier) if issue && priority_tier
      end

      if github_sync_args
        label_name, stale_labels = github_sync_args
        sync_priority_label_to_github(issue, label_name, stale_labels)
      end

      ProcessRunQueueJob.perform_later

      audit_event("agent_run.created", metadata: { agent_run_id: agent_run.id, project_name: @project.name, goal: goal })

      capacity_user = settings_owner || current_user
      admission = Capacity::RunAdmission.call(user: capacity_user, project: @project, goal: goal)
      notice = if admission[:allowed] && AgentRun.queued.count <= 1
        "Agent run created and will start momentarily."
      else
        "Agent run queued. It will start automatically when a slot opens."
      end

      redirect_to project_path(@project), notice: notice
    rescue NoRunnableRunnerError => e
      redirect_to on_error_path, alert: e.message
    rescue InvalidDockerHostSelectionError => e
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

    def runner_key_to_agent_type(runner_key)
      Runner.agent_type_for(runner_key)
    end

    def agent_type_to_runner_key(agent_type)
      Runner.runner_key_for_agent_type(agent_type)
    end

    def managed_runner_key?(runner_key)
      Runner.supported_runner_key?(runner_key)
    end

    def retry_runner_options_for(agent_run)
      current_runner = current_retry_runner_for(agent_run)

      enabled_retry_runner_entries.filter_map do |identifier, runner|
        agent_type = runner_key_to_agent_type(runner.runner_key)
        next unless AgentRun::AGENT_TYPES.include?(agent_type)

        {
          runner_key: identifier,
          agent_type: agent_type,
          label: runner.display_name,
          current: current_runner.present? && runner.id == current_runner.id
        }
      end
    end

    def current_retry_runner_for(agent_run)
      return agent_run.runner if agent_run.runner

      runner_key = agent_type_to_runner_key(agent_run.agent_type)
      return unless runner_key

      Runner.for_identifier(settings_owner, runner_key)
    end

    def retry_agent_type_for(agent_run)
      requested_runner_identifier = params[:runner].presence
      requested_agent_type = params[:agent_type].presence

      return agent_run.agent_type if requested_runner_identifier.blank? && requested_agent_type.blank?

      if requested_runner_identifier.present?
        runner = configured_runner_for_retry(requested_runner_identifier)
        return nil unless runner

        requested_agent_type = runner_key_to_agent_type(runner.runner_key)
      end
      return nil unless retry_agent_type_allowed?(requested_agent_type)

      requested_agent_type
    end

    def retry_agent_type_allowed?(agent_type)
      return false unless AgentRun::AGENT_TYPES.include?(agent_type)

      runner_key = agent_type_to_runner_key(agent_type)
      return true unless managed_runner_key?(runner_key)

      enabled_retry_runners.any? { |runner| runner.runner_key == runner_key }
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

    def resolve_runner_selection(requested_agent_type:, requested_runner_identifier:, goal:)
      owner = settings_owner
      return unless owner

      configured_identifiers = UserSetting.enabled_agent_runners(owner, identifiers: true)
      priority_identifiers = owner.settings.runner_priority_for_goal(goal, identifiers: true)
      default_identifier = priority_identifiers.first

      if requested_runner_identifier.present?
        runner = configured_runner_for_retry(requested_runner_identifier)
        return runner if runner
      end

      if requested_agent_type.present? && AgentRun::AGENT_TYPES.include?(requested_agent_type)
        requested_runner_key = agent_type_to_runner_key(requested_agent_type)
        matches = enabled_retry_runners.select { |entry| entry.runner_key == requested_runner_key }
        runner = matches.find(&:subscription?) || matches.first
        return runner if runner
      end

      selected_identifier = if configured_identifiers.include?(default_identifier)
        default_identifier
      else
        priority_identifiers.first || configured_identifiers.first
      end

      runner_for_identifier(selected_identifier) || Runner.ensure_default_for(owner)
    end

    def runner_for_identifier(identifier)
      Runner.for_identifier(settings_owner, identifier)
    end

    # Returns [identifier, runner] pairs for all enabled agent runners,
    # bulk-loaded in two queries to avoid N+1.
    def enabled_retry_runner_entries
      @enabled_retry_runner_entries ||= begin
        owner = settings_owner
        unless owner
          []
        else
          identifiers = UserSetting.enabled_agent_runners(owner, identifiers: true)

          routing_ids = []
          plain_keys = []
          identifiers.each do |id|
            if Runner.routing_key?(id)
              routing_ids << Runner.id_from_routing_key(id)
            else
              plain_keys << id
            end
          end

          runners_by_id = owner.runners.kept_only.where(id: routing_ids).index_by(&:id)
          runners_by_key = owner.runners.kept_only.where(runner_key: plain_keys).ordered
            .group_by(&:runner_key)

          identifiers.filter_map do |identifier|
            runner = if Runner.routing_key?(identifier)
              runners_by_id[Runner.id_from_routing_key(identifier)]
            else
              group = runners_by_key[identifier]
              next unless group
              # Prefer subscription entry, matching Runner.for_identifier behavior
              group.find(&:subscription?) || group.first
            end
            next unless runner

            [ identifier, runner ]
          end
        end
      end
    end

    def settings_owner
      @settings_owner ||= @project.effective_owner
    end

    def enabled_retry_runners
      @enabled_retry_runners ||= enabled_retry_runner_entries.map(&:last)
    end

    def configured_runner_for_retry(identifier)
      return if identifier.blank?

      identifier = identifier.to_s
      if Runner.routing_key?(identifier)
        enabled_retry_runners.find { |entry| entry.routing_key == identifier }
      else
        # Prefer subscription entry when multiple runners share the same key,
        # matching Runner.for_identifier backward-compat behavior.
        matches = enabled_retry_runners.select { |entry| entry.runner_key == identifier }
        matches.find(&:subscription?) || matches.first
      end
    end

    def termination_guardrail_type(agent_run)
      agent_run.guardrail_violation_type.presence ||
        agent_run.guardrail_context&.dig("violation_type").presence ||
        "unknown"
    end

    def safe_return_target
      normalized_return_to(params[:return_to])
    end

    def normalized_return_to(candidate)
      return if candidate.blank?

      candidate = candidate.to_s
      return unless candidate.start_with?("/") && !candidate.start_with?("//")

      url_from(candidate)
    rescue URI::InvalidURIError
      nil
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
    rescue NoRunnableRunnerError => e
      redirect_to on_error_path, alert: e.message
    rescue InvalidDockerHostSelectionError => e
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
    rescue NoRunnableRunnerError => e
      redirect_to on_error_path, alert: e.message
    rescue InvalidDockerHostSelectionError => e
      redirect_to on_error_path, alert: e.message
    rescue ActiveRecord::RecordNotUnique
      redirect_to on_error_path, alert: "An unexpected error occurred. Please try again."
    end

    def create_feature_run_and_redirect(feature_description:, on_error_path:, priority_tier: nil)
      budget_result = CostBudgets::Check.call(@project)
      unless budget_result[:allowed]
        redirect_to on_error_path, alert: "Your project's AI budget has been reached. Please adjust your budget settings or try again later."
        return
      end

      # Extract a short title from the first line of the description.
      title = feature_description.lines.first&.strip&.truncate(120) || "New Feature"
      body = feature_description

      # Create a GitHub issue to hold the feature brief and clarifying questions.
      client = @project.client
      unless client
        redirect_to on_error_path, alert: "GitHub access is not configured for this project."
        return
      end

      gh_issue = client.create_issue(
        @project.full_name,
        title: "[Feature] #{title}",
        body: body
      )
      issue = Issues::UpsertFromGithub.call(project: @project, github_issue: gh_issue)

      # Build an initial feature brief from the description.
      feature_brief = {
        "title" => title,
        "problem" => feature_description
      }

      agent_run = nil
      github_sync_args = nil
      ActiveRecord::Base.transaction do
        agent_run = create_agent_run(
          issue: issue,
          custom_prompt: nil,
          goal: "create_feature",
          priority_tier: priority_tier
        )
        # Store the feature brief in external_metadata.
        agent_run.update!(external_metadata: agent_run.external_metadata.merge("feature_brief" => feature_brief))
        github_sync_args = apply_priority_label(issue, priority_tier) if priority_tier
      end

      if github_sync_args
        label_name, stale_labels = github_sync_args
        sync_priority_label_to_github(issue, label_name, stale_labels)
      end

      ProcessRunQueueJob.perform_later

      audit_event("agent_run.created", metadata: { agent_run_id: agent_run.id, project_name: @project.name, goal: "create_feature" })

      notice = "Feature creation run queued. The agent will analyze your description and may ask clarifying questions if more detail is needed."
      redirect_to project_path(@project), notice: notice
    rescue NoRunnableRunnerError => e
      redirect_to on_error_path, alert: e.message
    rescue InvalidDockerHostSelectionError => e
      redirect_to on_error_path, alert: e.message
    rescue ActiveRecord::RecordInvalid => e
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

    def available_run_runner_options
      enabled_retry_runner_entries.map do |identifier, runner|
        [ runner.display_name, identifier ]
      end
    end

    def available_docker_host_options(include_inherit: false, runner: nil, eligible_hosts: nil)
      options = []
      options << [ "Inherit saved placement preference", "" ] if include_inherit

      active_runs_by_host = AgentRun.joins(:project)
        .where(projects: { account_id: @project.account_id }, status: AgentRun::UNFINISHED_STATUSES)
        .group(:container_host)
        .count

      eligible_hosts ||= docker_host_selection_context(runner: runner)[:eligible_hosts]

      options + eligible_hosts.map do |host|
        active_runs = active_runs_by_host.fetch(host.identifier, 0)
        [ "#{host.display_name} (#{host.backend_type}, #{host.available_slots(active_run_count: active_runs)} slots free)", host.identifier ]
      end
    end

    def runner_for_docker_host_param
      identifier = params[:runner].to_s.presence
      return if identifier.blank?

      runner_for_identifier(identifier)
    end

    def current_eligible_host_identifier(runner: nil, eligible_hosts: nil)
      preferred_identifier = @project.effective_preferred_docker_host_identifier
      return nil if preferred_identifier.blank?

      eligible_hosts ||= docker_host_selection_context(runner: runner)[:eligible_hosts]
      eligible_hosts.find { |host| host.identifier == preferred_identifier }&.identifier
    end


    def resolved_container_host_attributes(runner: nil)
      Containers::ResolveHostForRun.call(
        project: @project,
        runner: runner,
        account: current_account,
        requested_container_host: params[:container_host].to_s.presence
      )
    end

    def docker_host_selection_context(runner: nil)
      @docker_host_selection_contexts ||= {}
      cache_key = runner&.id || runner&.runner_key || :none
      @docker_host_selection_contexts[cache_key] ||= begin
        auth_source = runner&.subscription? ? subscription_auth_source_for(runner) : nil
        {
          auth_source: auth_source,
          eligible_hosts: eligible_docker_hosts_for_manual_selection(auth_source: auth_source)
        }
      end
    end

    def eligible_docker_hosts_for_manual_selection(auth_source: nil)
      current_account.docker_hosts.enabled.ordered.select do |host|
        docker_host_eligible_for_manual_selection?(host, auth_source: auth_source)
      end
    end

    def docker_host_eligible_for_manual_selection?(host, auth_source: nil)
      return false unless host.placement_ready?
      return true if auth_source.nil?

      subscription_auth_eligibility_for(host, auth_source: auth_source).eligible?
    end

    def subscription_auth_eligibility_for(host, auth_source:)
      Runners::SubscriptionAuthEligibility.call(
        backend: docker_host_backend_capabilities(host),
        auth_source: auth_source,
        proxy_reachable: host.required_network_status == "ready"
      )
    end

    def docker_host_backend_capabilities(host)
      Struct.new(:identifier, :supports_host_paths?).new(host.identifier, host.local?)
    end

    def subscription_auth_source_for(runner)
      runner_key = runner.runner_key.to_s
      credential = managed_subscription_credential_for(runner_key, require_active: false)

      if credential
        return Runners::SubscriptionAuthEligibility::AuthSource.new(
          runner_key: runner_key,
          auth_mode: :managed,
          credential_state: managed_credential_state_for(runner_key, credential)
        )
      end

      if api_key_proxy_subscription_auth_for?(runner_key)
        return Runners::SubscriptionAuthEligibility::AuthSource.new(
          runner_key: runner_key,
          auth_mode: :api_key_proxy
        )
      end

      Runners::SubscriptionAuthEligibility::AuthSource.new(
        runner_key: runner_key,
        auth_mode: :host_forwarded
      )
    end

    API_KEY_PROXY_SUBSCRIPTION_RUNNERS = %w[codex].freeze

    def api_key_proxy_subscription_auth_for?(runner_key)
      API_KEY_PROXY_SUBSCRIPTION_RUNNERS.include?(runner_key)
    end

    def managed_subscription_credential_for(runner_key, require_active: true)
      scope = current_account.runner_credentials.for_runner(runner_key)
      scope = scope.where(auth_kind: "oauth_token") if %w[claude codex gemini copilot].include?(runner_key.to_s)
      scope = scope.active if require_active
      scope.order(created_at: :desc, id: :desc).first
    end

    def managed_credential_state_for(runner_key, credential)
      return :expired if credential.revoked?
      return :expired unless credential.active?

      provider = Runners::SubscriptionAuthProviders.for_runner(runner_key)
      status = provider&.status(secret: credential.token.to_s)
      return :expired if status&.expired?

      :active
    end

    def default_runner_for_goal(goal)
      identifier = settings_owner&.settings&.default_runner_identifier_for_goal(goal)
      return if identifier.blank?

      Runner.for_identifier(settings_owner, identifier)
    end
  end
end
