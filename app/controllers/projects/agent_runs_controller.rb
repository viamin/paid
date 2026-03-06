# frozen_string_literal: true

module Projects
  class AgentRunsController < ApplicationController
    before_action :set_project
    before_action :set_agent_run, only: [ :show, :retry, :refresh_auth ]

    def index
      authorize @project, :show?
      base_scope = @project.agent_runs
      @q = base_scope.ransack(params[:q])
      @q.sorts = "created_at desc" if @q.sorts.empty?
      @pagy, @agent_runs = pagy(@q.result)
    end

    def show
      authorize @agent_run
      @logs = @agent_run.agent_run_logs.order(created_at: :asc).limit(500).load
    end

    def new
      authorize @project, :run_agent?
      @default_agent_type = provider_key_to_agent_type(current_user.settings.default_agent_provider)
      @issues = @project.issues
        .issues_only
        .where(github_state: "open")
        .where(paid_state: %w[new planning failed])
        .order(github_number: :desc)
      @pull_requests = @project.issues
        .pull_requests_only
        .where(github_state: "open")
        .order(github_number: :desc)
    end

    def create
      authorize @project, :run_agent?

      custom_prompt = params[:custom_prompt]&.strip.presence
      issue = resolve_issue
      source_pr_number = resolve_pull_request

      unless issue || custom_prompt || source_pr_number
        redirect_to new_project_agent_run_path(@project),
          alert: "Please select an issue, provide a custom prompt, or select a pull request."
        return
      end

      create_run_and_redirect(
        on_error_path: new_project_agent_run_path(@project),
        issue: issue,
        custom_prompt: custom_prompt,
        source_pull_request_number: source_pr_number
      )
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

      create_run_and_redirect(
        on_error_path: project_path(@project),
        issue: issue,
        agent_type: current_user.settings.default_agent_provider,
        goal: "create_pr",
        source_pull_request_number: source_pr_number
      )
    end

    def retry
      authorize @agent_run

      unless @agent_run.finished?
        redirect_to project_agent_run_path(@project, @agent_run),
          alert: "Only finished runs can be retried."
        return
      end

      new_run = AgentRun.create!(
        project: @project,
        issue: @agent_run.issue,
        agent_type: @agent_run.agent_type,
        custom_prompt: @agent_run.custom_prompt,
        source_pull_request_number: @agent_run.source_pull_request_number,
        goal: @agent_run.goal,
        trigger_type: "manual",
        status: "queued"
      )

      @agent_run.retry!

      ProcessRunQueueJob.perform_later

      redirect_to project_agent_run_path(@project, new_run),
        notice: "Agent run queued as a retry of run ##{@agent_run.id}."
    rescue ActiveRecord::RecordNotUnique => e
      alert = if e.cause&.message&.include?("proxy_token")
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

      code = params[:auth_code]&.strip
      if code.blank?
        redirect_to project_agent_run_path(@project, @agent_run),
          alert: "Please provide an authentication code."
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

      AgentHarness.refresh_auth(provider, code: code)

      new_run = AgentRun.create!(
        project: @project,
        issue: @agent_run.issue,
        agent_type: @agent_run.agent_type,
        custom_prompt: @agent_run.custom_prompt,
        source_pull_request_number: @agent_run.source_pull_request_number,
        goal: @agent_run.goal,
        trigger_type: "manual",
        status: "queued"
      )
      @agent_run.retry!
      ProcessRunQueueJob.perform_later

      redirect_to project_agent_run_path(@project, new_run),
        notice: "Authentication refreshed. Agent run queued for retry."
    # Catch all harness errors (including AuthenticationError, which is a
    # subclass of Error) so this works even when the shim hasn't loaded yet.
    rescue AgentHarness::Error => e
      Rails.logger.error(
        message: "agent_execution.refresh_auth_failed",
        agent_run_id: @agent_run.id,
        error_class: e.class.name,
        error_message: e.message
      )
      redirect_to project_agent_run_path(@project, @agent_run),
        alert: "Re-authentication failed: #{e.message}"
    rescue ActiveRecord::RecordNotUnique => e
      alert = if e.cause&.message&.include?("proxy_token")
        "An unexpected error occurred. Please try again."
      else
        "An agent run is already queued or in progress for this issue."
      end
      redirect_to project_agent_run_path(@project, @agent_run), alert: alert
    end

    private

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

    def resolve_pull_request
      return nil if params[:pull_request_id].blank?

      pr = @project.issues.pull_requests_only.find(params[:pull_request_id])
      pr.github_number
    end

    def create_agent_run(issue: nil, custom_prompt: nil, source_pull_request_number: nil, agent_type: nil, goal: nil)
      configured_providers = UserSetting.enabled_agent_providers(current_user)
      default_provider = current_user.settings.default_agent_provider

      requested_agent_type = agent_type || params[:agent_type].presence
      resolved_agent_type = nil

      if requested_agent_type.present? && AgentRun::AGENT_TYPES.include?(requested_agent_type)
        requested_provider_key = agent_type_to_provider_key(requested_agent_type)
        if managed_provider_key?(requested_provider_key) && !configured_providers.include?(requested_provider_key)
          requested_agent_type = nil
        else
          resolved_agent_type = requested_agent_type
        end
      end

      unless resolved_agent_type
        provider_key = requested_agent_type || default_provider || "claude"
        provider_key = default_provider if configured_providers.include?(default_provider) && !configured_providers.include?(provider_key)
        provider_key = configured_providers.first if configured_providers.any? && !configured_providers.include?(provider_key)

        resolved_agent_type = provider_key_to_agent_type(provider_key)
        resolved_agent_type = "claude_code" unless AgentRun::AGENT_TYPES.include?(resolved_agent_type)
      end

      if managed_provider_key?(agent_type_to_provider_key(resolved_agent_type))
        provider_key = agent_type_to_provider_key(resolved_agent_type)
        unless configured_providers.include?(provider_key)
          fallback_key = if configured_providers.any?
            configured_providers.first
          else
            "claude"
          end
          resolved_agent_type = provider_key_to_agent_type(fallback_key)
        end
      else
        resolved_agent_type = "claude_code" unless AgentRun::AGENT_TYPES.include?(resolved_agent_type)
      end

      goal ||= params[:goal].presence || "create_pr"
      goal = "create_pr" unless AgentRun::GOALS.include?(goal)

      AgentRun.create!(
        project: @project,
        issue: issue,
        agent_type: resolved_agent_type,
        custom_prompt: custom_prompt,
        source_pull_request_number: source_pull_request_number,
        goal: goal,
        trigger_type: "manual",
        status: "queued"
      )
    end

    def create_run_and_redirect(on_error_path:, **attrs)
      create_agent_run(**attrs)
      ProcessRunQueueJob.perform_later

      notice = if AgentRun.has_run_capacity? && AgentRun.queued.count <= 1
        "Agent run created and will start momentarily."
      else
        "Agent run queued. It will start automatically when a slot opens."
      end

      redirect_to project_path(@project), notice: notice
    rescue ActiveRecord::RecordNotUnique => e
      alert = if e.cause&.message&.include?("proxy_token")
        "An unexpected error occurred. Please try again."
      else
        "An agent run is already queued or in progress."
      end
      redirect_to on_error_path, alert: alert
    end

    def provider_key_to_agent_type(provider_key)
      return "claude_code" if provider_key == "claude"

      provider_key
    end

    def agent_type_to_provider_key(agent_type)
      return "claude" if agent_type == "claude_code"

      agent_type
    end

    def managed_provider_key?(provider_key)
      Provider::SUPPORTED_PROVIDER_KEYS.include?(provider_key)
    end
  end
end
