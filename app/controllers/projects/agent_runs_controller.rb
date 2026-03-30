# frozen_string_literal: true

module Projects
  class AgentRunsController < ApplicationController
    before_action :set_project
    before_action :set_agent_run, only: [ :show, :retry, :refresh_auth ]

    def index
      authorize @project, :show?
      base_scope = @project.agent_runs.includes(issue: :project)
      @q = base_scope.ransack(params[:q])
      @q.sorts = "created_at desc" if @q.sorts.empty?
      @pagy, @agent_runs = pagy(@q.result)
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

    def new
      authorize @project, :run_agent?
      @default_provider_identifier = current_user.settings.provider_priority(identifiers: true).first
      @available_run_provider_options = available_run_provider_options
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

      goal = params[:goal].presence || "create_pr"
      custom_prompt = params[:custom_prompt]&.strip.presence
      issue = resolve_issue
      source_pr_number = resolve_pull_request

      if goal == "review"
        unless source_pr_number
          redirect_to new_project_agent_run_path(@project, goal: goal),
            alert: "Please select a pull request to review."
          return
        end
      else
        unless issue || custom_prompt || source_pr_number
          redirect_to new_project_agent_run_path(@project, goal: goal),
            alert: "Please select an issue, provide a custom prompt, or select a pull request."
          return
        end
      end

      create_run_and_redirect(
        on_error_path: new_project_agent_run_path(@project, goal: goal),
        issue: issue,
        custom_prompt: custom_prompt,
        source_pull_request_number: source_pr_number,
        goal: goal
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

      if issue&.associated_pull_request
        redirect_to project_path(@project),
          alert: "This issue already has an associated pull request."
        return
      end

      create_run_and_redirect(
        on_error_path: project_path(@project),
        issue: issue,
        provider_identifier: current_user.settings.default_provider_identifier,
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
        .where(status: "queued")

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
      end

      @project.broadcast_pull_requests_update

      action = pr.auto_continue_paused? ? "paused" : "resumed"
      redirect_to project_path(@project), notice: "Auto-continue #{action} for PR ##{pr.github_number}."
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

      new_run = AgentRun.create!(
        project: @project,
        issue: @agent_run.issue,
        provider: retry_provider,
        agent_type: agent_type,
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
        provider: @agent_run.provider,
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

    def resolve_pull_request_record
      return nil if params[:pull_request_id].blank?

      @project.issues.pull_requests_only.find_by(id: params[:pull_request_id])
    end

    def create_agent_run(issue: nil, custom_prompt: nil, source_pull_request_number: nil, agent_type: nil, provider_identifier: nil, goal: nil)
      requested_agent_type = agent_type || params[:agent_type].presence
      requested_provider_identifier = provider_identifier || params[:provider].presence
      resolved_provider = resolve_provider_selection(
        requested_agent_type: requested_agent_type,
        requested_provider_identifier: requested_provider_identifier
      )
      resolved_agent_type = provider_key_to_agent_type(resolved_provider.provider_key)

      goal ||= params[:goal].presence || "create_pr"
      goal = "create_pr" unless AgentRun::GOALS.include?(goal)

      AgentRun.create!(
        project: @project,
        issue: issue,
        provider: resolved_provider,
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

      capacity_user = @project.created_by || current_user
      notice = if AgentRun.has_run_capacity?(user: capacity_user) && AgentRun.queued.count <= 1
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

      Provider.for_identifier(current_user, provider_key)
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

    def resolve_provider_selection(requested_agent_type:, requested_provider_identifier:)
      configured_identifiers = UserSetting.enabled_agent_providers(current_user, identifiers: true)
      priority_identifiers = current_user.settings.provider_priority(identifiers: true)
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

      provider_for_identifier(selected_identifier) || Provider.ensure_default_for(current_user)
    end

    def provider_for_identifier(identifier)
      Provider.for_identifier(current_user, identifier)
    end

    # Returns [identifier, provider] pairs for all enabled agent providers,
    # bulk-loaded in two queries to avoid N+1.
    def enabled_retry_provider_entries
      @enabled_retry_provider_entries ||= begin
        identifiers = UserSetting.enabled_agent_providers(current_user, identifiers: true)

        routing_ids = []
        plain_keys = []
        identifiers.each do |id|
          if Provider.routing_key?(id)
            routing_ids << Provider.id_from_routing_key(id)
          else
            plain_keys << id
          end
        end

        providers_by_id = current_user.providers.where(id: routing_ids).index_by(&:id)
        providers_by_key = current_user.providers.where(provider_key: plain_keys).ordered
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

    def available_run_provider_options
      enabled_retry_provider_entries.map do |identifier, provider|
        [ provider.display_name, identifier ]
      end
    end
  end
end
