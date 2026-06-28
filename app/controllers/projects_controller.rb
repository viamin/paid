# frozen_string_literal: true

class ProjectsController < ApplicationController
  include AuditLogging

  before_action :set_project, only: [ :show, :edit, :update, :destroy, :toggle_auto_pick, :toggle_auto_merge, :toggle_pause, :quality_resume, :detect_services, :detect_screenshot_settings, :commit_screenshot_config, :ensure_labels, :cleanup_stale_runs ]
  skip_after_action :verify_authorized, only: :index

  NULLS_LAST_SORT_ATTRIBUTES = %w[last_agent_run_at last_github_activity_at].freeze
  AUTO_PICK_PARTIALS = {
    "index" => "projects/auto_pick_toggle_index"
  }.freeze
  AUTO_MERGE_PARTIALS = {
    "index" => "projects/auto_merge_toggle_index"
  }.freeze

  def index
    base_scope = policy_scope(Project).includes(:github_token, :github_installation)
    @q = base_scope.ransack(params[:q])
    @q.sorts = "last_agent_run_at desc" if @q.sorts.empty?
    @projects = apply_nulls_last_ordering(@q.result)
  end

  def show
    authorize @project
    tracker_configuration = IssueTrackers::ResolveConfiguration.call(project: @project, user: current_user)
    @external_links = @project.header_external_links(tracker_configuration: tracker_configuration)
    @recent_agent_runs = @project.agent_runs.recent.includes(:runner, :issue, project: [ :created_by, :account ]).limit(10).to_a
    AgentRun.preload_final_runner_records(@recent_agent_runs)
    @stale_agent_runs_count = @project.agent_runs.stale_for_cleanup.count
    @show_stale_cleanup_action = policy(@project).update? && @stale_agent_runs_count.positive?
    AgentRun.preload_source_pull_requests(@recent_agent_runs)
    AgentRun.preload_created_issue_records(@recent_agent_runs)
    settings = current_user.settings
    open_items = @project.issues.where(github_state: "open").order(github_number: :desc)
    @issues = open_items.issues_only.includes(:sub_issues).limit(settings.max_issues_per_page)
    @issue_lifecycle_statuses = Issue.lifecycle_statuses(@issues)
    @paid_prs_by_issue_id = Issue.open_paid_generated_prs_by_issue_id(
      project: @project, issue_ids: @issues.map(&:id)
    )
    @pull_requests = open_items.pull_requests_only.limit(settings.max_prs_per_page)
    visible_issue_ids = @issues.map(&:id) + @pull_requests.map(&:id)
    @merge_notification_issue_ids = current_user.issue_merge_subscriptions.on_merge
      .where(issue_id: visible_issue_ids)
      .pluck(:issue_id)
    @paused_agent_runs = @project.agent_runs.paused
      .includes(:issue, :runner, project: [ :created_by, :account ])
      .order(paused_at: :desc, created_at: :desc)
      .to_a
    AgentRun.preload_final_runner_records(@paused_agent_runs)
    @paused_runs_by_issue_id = @paused_agent_runs.each_with_object({}) do |run, h|
      h[run.issue_id] ||= run if run.issue_id.present?
    end
    @paused_runs_by_pr_number = @paused_agent_runs.each_with_object({}) do |run, h|
      h[run.source_pull_request_number] ||= run if run.source_pull_request_number.present?
    end
    @pr_numbers_with_queued_auto_continue = @project.pr_numbers_with_queued_auto_continue
    @pr_numbers_with_active_runs = @project.pr_numbers_with_active_runs
    @cost_budgets = @project.cost_budgets.load
    @quality_summary = QualityMetrics::DashboardStats.overview(project: @project)
    if @project.auto_merge_enabled?
      @recent_merged_pull_requests = @project.issues
        .pull_requests_only
        .where(github_state: "closed", pr_review_phase: "merged")
        .includes(:parent_issue)
        .order(github_updated_at: :desc, updated_at: :desc)
        .limit(10)

      closing_issue_numbers = @recent_merged_pull_requests.flat_map(&:closing_referenced_issue_numbers).uniq
      @merged_pull_request_closed_issues_by_number =
        if closing_issue_numbers.any?
          @project.issues
            .issues_only
            .where(github_number: closing_issue_numbers)
            .index_by(&:github_number)
        else
          {}
        end
    else
      @recent_merged_pull_requests = Issue.none
      @merged_pull_request_closed_issues_by_number = {}
    end
    @collector_runs = CollectorRun
      .joins(:project_version)
      .where(project_versions: { project_id: @project.id })
      .includes(:project_version)
      .order(created_at: :desc)
      .limit(20)
    @latest_failed_collector_runs =
      if @project.knowledge_status == "failed"
        failed_collector_runs_for_latest_version
      else
        CollectorRun.none
      end
    @artifact_counts = Rails.cache.fetch(
      KnowledgeArtifact.artifact_counts_cache_key(@project.id),
      expires_in: 10.minutes
    ) do
      KnowledgeArtifact.active
        .for_project(@project)
        .group(:artifact_type)
        .count
        .sort_by { |_, count| -count }
    end
  end

  def new
    @project = current_account.projects.build
    @github_tokens = policy_scope(GithubToken).where(revoked_at: nil)
    @github_installations = policy_scope(GithubInstallation).active
    authorize @project
  end

  def create
    @project = current_account.projects.build(project_params)
    assign_selected_github_credential(@project)
    @project.created_by = current_user
    @project.allowed_github_usernames = [ @project.owner ] if @project.allowed_github_usernames.blank?
    authorize @project

    @github_tokens = policy_scope(GithubToken).where(revoked_at: nil)
    @github_installations = policy_scope(GithubInstallation).active

    unless @project.github_credential_present?
      @project.errors.add(:base, "must select either a GitHub token or GitHub App installation")
      return render :new, status: :unprocessable_content
    end

    if @project.github_id.present? && @project.default_branch.present?
      save_project_with_cached_data
    else
      fetch_github_metadata
    end
  end

  def edit
    authorize @project
    @github_tokens = policy_scope(GithubToken).where(revoked_at: nil)
    @github_installations = policy_scope(GithubInstallation).active
    @github_auth_source = selected_github_auth_source
    @paid_agents_installation = @project.paid_agents_installation(installations: @github_installations)
    @available_service_containers = policy_scope(ServiceContainer).where.not(id: @project.service_container_ids).order(:name)
    @available_mcp_server_definitions = policy_scope(McpServerDefinition).where.not(id: @project.mcp_server_definition_ids).order(:name)
    @project_mcp_servers = @project.project_mcp_servers.includes(:mcp_server_definition).to_a
    @mutation_req = @project.pre_commit_requirements.find_by(check_type: "mutation_test")
    load_screenshot_settings_context
  end

  def update
    authorize @project
    @github_tokens = policy_scope(GithubToken).where(revoked_at: nil)
    @github_installations = policy_scope(GithubInstallation).active

    update_params = project_params
    @github_auth_source = selected_github_auth_source(update_params)
    @paid_agents_installation = @project.paid_agents_installation(installations: @github_installations)
    update_params = update_params.merge(allowed_github_usernames: parse_usernames_csv) if params.dig(:project, :allowed_github_usernames_csv)
    update_params = update_params.merge(auto_pick_skip_labels: parse_auto_pick_skip_labels) if auto_pick_skip_labels_param_submitted?
    update_params = update_params.merge(review_settings: build_review_settings) if params.dig(:project, :review_settings)
    update_params = update_params.merge(screenshot_settings: build_screenshot_settings) if params.dig(:project, :screenshot_settings)
    if screenshot_action_requested?
      return handle_screenshot_action(update_params[:screenshot_settings] || @project.effective_screenshot_settings)
    end

    assign_selected_github_credential(@project, update_params)
    update_params = update_params.except(:github_auth_source, :github_token_id, :github_installation_id)

    if @project.update(update_params)
      audit_event("project.updated", metadata: { name: @project.name, changed_fields: @project.saved_changes.except("updated_at").keys })
      redirect_to @project, notice: "Project was successfully updated."
    else
      ensure_github_app_installation_error
      @available_service_containers = policy_scope(ServiceContainer).where.not(id: @project.service_container_ids).order(:name)
      @available_mcp_server_definitions = policy_scope(McpServerDefinition).where.not(id: @project.mcp_server_definition_ids).order(:name)
      @project_mcp_servers = @project.project_mcp_servers.includes(:mcp_server_definition).to_a
      load_screenshot_settings_context
      render :edit, status: :unprocessable_content
    end
  end

  def toggle_auto_pick
    toggle_automation(:auto_pick, AUTO_PICK_PARTIALS)
  end

  def toggle_auto_merge
    authorize @project, :update?
    next_mode = case @project.auto_merge_mode
    when "off" then "dependabot_only"
    when "dependabot_only" then "all"
    else "off"
    end
    @project.update!(auto_merge_mode: next_mode)

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          ActionView::RecordIdentifier.dom_id(@project, :auto_merge_toggle),
          partial: "projects/auto_merge_toggle_index",
          locals: { project: @project }
        )
      end
      format.html { redirect_to @project }
    end
  end

  def toggle_pause
    authorize @project, :update?
    if @project.paused?
      @project.unpause!
    else
      @project.pause!
    end

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          ActionView::RecordIdentifier.dom_id(@project, :pause_toggle),
          partial: "projects/pause_toggle",
          locals: { project: @project }
        )
      end
      format.html { redirect_to @project }
    end
  end

  def quality_resume
    authorize @project, :update?

    resumed = @project.quality_resume!(
      metadata: {
        resumed_by_user_id: current_user.id,
        resumed_by_user_email: current_user.email
      }
    )

    respond_to do |format|
      format.html do
        if resumed
          redirect_to edit_project_path(@project), notice: "Quality pause was resumed."
        else
          redirect_to edit_project_path(@project), notice: "Project is not quality-paused."
        end
      end
      format.json { render json: { resumed: resumed, quality_paused: @project.reload.quality_paused? } }
    end
  end

  def detect_services
    authorize @project, :update?

    result = Projects::DetectServices.call(project: @project)

    if result.any_detected?
      added = result.apply(@project)
      redirect_to edit_project_path(@project), notice: result.notice_message(added)
    else
      redirect_to edit_project_path(@project), notice: "No service dependencies detected in repository files."
    end
  rescue GithubClient::Error => e
    redirect_to edit_project_path(@project), alert: "Could not detect services: #{e.message}"
  end

  def detect_screenshot_settings
    authorize @project, :update?

    perform_screenshot_detection(screenshot_settings_for_action)
  rescue GithubClient::Error => e
    redirect_to edit_project_path(@project, anchor: "screenshots"),
      alert: "Could not detect screenshot settings: #{e.message}"
  end

  def commit_screenshot_config
    authorize @project, :update?

    perform_screenshot_commit(screenshot_settings_for_action)
  rescue GithubClient::Error, Octokit::Error => e
    redirect_to edit_project_path(@project, anchor: "screenshots"),
      alert: "Could not commit screenshot config: #{e.message}"
  end

  def ensure_labels
    authorize @project, :update?

    result = Projects::EnsureStandardLabels.call(project: @project)

    if result.any_errors?
      redirect_to edit_project_path(@project), alert: result.notice_message
    else
      redirect_to edit_project_path(@project), notice: result.notice_message
    end
  rescue GithubClient::ApiError => e
    redirect_to edit_project_path(@project), alert: "Could not sync labels: #{e.message}"
  rescue GithubClient::AuthenticationError => e
    redirect_to edit_project_path(@project), alert: "GitHub authentication failed: #{e.message}"
  end

  def cleanup_stale_runs
    authorize @project, :update?

    cleaned_count = AgentRuns::CleanupStale.call(project: @project)
    message = cleaned_count.positive? ? "Cleaned up #{cleaned_count} stale agent run(s)." : "No stale agent runs needed cleanup."
    redirect_to project_path(@project), notice: message
  end

  def destroy
    authorize @project

    if params[:name_confirmation] != @project.name
      redirect_to edit_project_path(@project), alert: "Project name does not match. Please type the exact project name to confirm deletion."
      return
    end

    name = @project.name
    @project.destroy!
    audit_event("project.deleted", metadata: { name: name })
    redirect_to projects_path, notice: "Project was successfully deleted."
  end

  private

  def resolve_audit_subject
    @project
  end

  def toggle_automation(feature, partials)
    authorize @project, :update?
    attribute = :"#{feature}_enabled"
    @project.update!(attribute => !@project.public_send(:"#{attribute}?"))

    respond_to do |format|
      format.turbo_stream do
        partial = partials.fetch(params[:context], partials.fetch("index"))
        render turbo_stream: turbo_stream.replace(
          ActionView::RecordIdentifier.dom_id(@project, :"#{feature}_toggle"),
          partial: partial,
          locals: { project: @project }
        )
      end
      format.html { redirect_to @project }
    end
  end

  def apply_nulls_last_ordering(scope)
    sort = @q.sorts.first
    return scope unless sort && NULLS_LAST_SORT_ATTRIBUTES.include?(sort.name)

    column = Project.arel_table[sort.name]
    direction = sort.dir == "desc" ? column.desc : column.asc
    scope.reorder(direction.nulls_last, Project.arel_table[:created_at].desc)
  end

  def failed_collector_runs_for_latest_version
    latest_version_id = @project.project_versions.by_recency.pick(:id)
    return CollectorRun.none unless latest_version_id

    CollectorRun.failed.where(project_version_id: latest_version_id)
  end

  def assign_selected_github_credential(project, params_hash = project_params)
    github_auth_source = params_hash[:github_auth_source].presence
    github_token_id = params_hash[:github_token_id].presence
    github_installation_id = params_hash[:github_installation_id].presence

    if github_auth_source == "app"
      project.github_installation = project.paid_agents_installation(installations: @github_installations)
      project.github_token = nil
      return if project.github_installation.present?

      project.errors.add(:github_installation, "must be installed for #{project.full_name}")
    elsif github_auth_source == "pat"
      project.github_installation = nil
      project.github_token = current_account.github_tokens.find_by(id: github_token_id)
      project.errors.add(:github_token, "must belong to the same account") if github_token_id.present? && project.github_token.blank?
    elsif github_installation_id
      project.github_installation = current_account.github_installations.find_by(id: github_installation_id)
      project.errors.add(:github_installation, "must belong to the same account") if project.github_installation.blank?
      project.github_token = nil
    elsif github_token_id
      project.github_token = current_account.github_tokens.find_by(id: github_token_id)
      project.errors.add(:github_token, "must belong to the same account") if project.github_token.blank?
      project.github_installation = nil
    end
  end

  def set_project
    @project = policy_scope(Project).includes(:github_token, :github_installation, :created_by).find(params[:id])
  end

  def project_params
    params.require(:project).permit(:github_auth_source, :github_token_id, :github_installation_id,
      :git_push_pat_fallback_enabled, :git_push_fallback_token_id, :owner, :repo, :name, :active,
      :poll_interval_seconds, :max_execution_seconds, :github_id, :default_branch,
      :token_budget_max_input_tokens,
      :owner_reviewer_login, :merge_method, :max_draft_review_rounds, :auto_pick_enabled, :auto_merge_mode,
      :allow_bot_authored_pr_auto_merge, :auto_fix_merge_conflicts, :auto_scan_security,
      :generated_label_name, :automation_label_name,
      :enhance_issue_needs_input_label_name, :enhance_issue_enhanced_label_name,
      :max_enhance_issue_reevaluation_rounds,
      :auto_add_labels_enabled, :automation_on_label_enabled, :pr_aggregation_enabled,
      :inherit_priority_labels,
      :auto_enhance_enabled,
      :knowledge_evolution_enabled,
      :auto_release_granularity,
      :plan_review_timeout_hours,
      :max_issue_runner_failures,
      auto_pick_skip_labels: [],
      allowed_github_usernames: [],
      priority_labels: Project::PRIORITY_TIERS)
  end

  def selected_github_auth_source(params_hash = nil)
    source = params_hash&.[](:github_auth_source).presence || params.dig(:project, :github_auth_source).presence || @project.github_auth_source
    Project::GITHUB_AUTH_SOURCES.include?(source) ? source : @project.github_auth_source
  end

  def ensure_github_app_installation_error
    return unless @github_auth_source == "app"
    return if @paid_agents_installation.present?

    @project.errors.add(:github_installation, "must be installed for #{@project.full_name}")
  end

  TERMINATION_KEYS = %i[max_review_rounds max_review_goal_retries stop_when_no_comments quality_threshold timeout_minutes].freeze

  def build_review_settings
    termination_permit = { termination: TERMINATION_KEYS }
    rs = params.require(:project).permit(
      review_settings: [
        :enabled, :wait_for_reviews, :address_all_bot_reviews,
        { methods: {
          copilot: [ :enabled, termination_permit ],
          paid_agent: [ :enabled, termination_permit ],
          ci_action: [ :enabled, :action_name, termination_permit ],
          manual: [ :enabled, :reviewer_login, termination_permit ],
          codex: [ :enabled, termination_permit ]
        } }
      ]
    ).dig(:review_settings)

    return {} unless rs

    settings = rs.to_h
    cast_review_settings(settings)
  end

  def cast_review_settings(settings)
    settings["enabled"] = ActiveModel::Type::Boolean.new.cast(settings["enabled"]) if settings.key?("enabled")
    settings["wait_for_reviews"] = ActiveModel::Type::Boolean.new.cast(settings["wait_for_reviews"]) if settings.key?("wait_for_reviews")
    settings["address_all_bot_reviews"] = ActiveModel::Type::Boolean.new.cast(settings["address_all_bot_reviews"]) if settings.key?("address_all_bot_reviews")

    if settings["methods"].is_a?(Hash)
      settings["methods"].each_value do |config|
        next unless config.is_a?(Hash)

        config["enabled"] = ActiveModel::Type::Boolean.new.cast(config["enabled"]) if config.key?("enabled")
        config["action_name"] = config["action_name"].presence if config.key?("action_name")
        config["reviewer_login"] = config["reviewer_login"].presence if config.key?("reviewer_login")
        next unless config["termination"].is_a?(Hash)

        term = config["termination"]
        term["max_review_rounds"] = term["max_review_rounds"].present? ? term["max_review_rounds"].to_i : nil
        term["max_review_goal_retries"] = term["max_review_goal_retries"].present? ? term["max_review_goal_retries"].to_i : nil
        term["timeout_minutes"] = term["timeout_minutes"].present? ? term["timeout_minutes"].to_i : nil
        term["stop_when_no_comments"] = ActiveModel::Type::Boolean.new.cast(term["stop_when_no_comments"]) if term.key?("stop_when_no_comments")
        term["quality_threshold"] = term["quality_threshold"].presence
      end
    end

    settings
  end

  def build_screenshot_settings
    raw = params.require(:project).permit(
      screenshot_settings: [ :enabled, :driver, :config_path, :auto_capture, :setup_commands_text, { service_dependencies: [] } ]
    ).fetch(:screenshot_settings, {})

    existing = @project.effective_screenshot_settings
    existing.merge(
      "enabled" => ActiveModel::Type::Boolean.new.cast(raw[:enabled]),
      "driver" => raw[:driver].presence || existing["driver"],
      "config_path" => raw[:config_path].presence || Project::DEFAULT_SCREENSHOT_SETTINGS["config_path"],
      "auto_capture" => ActiveModel::Type::Boolean.new.cast(raw[:auto_capture]),
      "service_dependencies" => Array(raw[:service_dependencies]).map(&:to_s).map(&:strip).reject(&:blank?).uniq,
      "setup_commands" => raw[:setup_commands_text].to_s.lines.map(&:strip).reject(&:blank?).uniq
    )
  end

  def screenshot_settings_for_action
    return @project.effective_screenshot_settings unless params.dig(:project, :screenshot_settings)

    build_screenshot_settings
  end

  def screenshot_action_requested?
    params[:screenshot_action].present?
  end

  def handle_screenshot_action(settings)
    case params[:screenshot_action]
    when "detect"
      perform_screenshot_detection(settings)
    when "commit"
      perform_screenshot_commit(settings)
    else
      redirect_to edit_project_path(@project, anchor: "screenshots"),
        alert: "Unknown screenshot action."
    end
  rescue GithubClient::Error, Octokit::Error => e
    message = params[:screenshot_action] == "commit" ? "Could not commit screenshot config" : "Could not detect screenshot settings"
    redirect_to edit_project_path(@project, anchor: "screenshots"),
      alert: "#{message}: #{e.message}"
  end

  def perform_screenshot_detection(settings)
    detection = Projects::Screenshots::DetectFramework.call(project: @project)
    settings = settings.merge(
      "driver" => detection.driver,
      "service_dependencies" => detection.service_dependencies,
      "setup_commands" => detection.setup_commands,
      "detection" => {
        "framework" => detection.framework,
        "confidence" => detection.confidence,
        "suggested_config" => detection.suggested_config,
        "suggested_yaml" => detection.suggested_yaml,
        "detected_at" => detection.detected_at
      }
    )
    @project.update!(screenshot_settings: settings)

    redirect_to edit_project_path(@project, anchor: "screenshots"),
      notice: "Detected #{detection.framework} with #{detection.confidence} confidence."
  end

  def perform_screenshot_commit(settings)
    repo_config = Projects::Screenshots::RepoConfig.call(
      project: @project,
      path: settings["config_path"]
    ).config
    generated_yaml = YAML.dump(@project.screenshot_preview_config(
      repo_config: repo_config,
      settings: settings
    ))

    result = Projects::Screenshots::CommitConfig.call(
      project: @project,
      config_path: settings["config_path"],
      content: generated_yaml
    )

    @project.update!(
      screenshot_settings: settings.deep_merge(
        "detection" => settings.fetch("detection", {}).merge(
          "suggested_yaml" => generated_yaml,
          "commit_pull_request_url" => result.pull_request_url
        )
      )
    )

    redirect_to edit_project_path(@project, anchor: "screenshots"),
      notice: "Created screenshot config PR: #{result.pull_request_url}"
  end

  def ensure_labels_best_effort(project)
    Projects::EnsureStandardLabels.call(project: project)
  rescue => e
    Rails.logger.warn(message: "github_sync.ensure_labels_on_create_failed", project_id: project.id, error: e.message)
  end

  def parse_usernames_csv
    params.dig(:project, :allowed_github_usernames_csv).to_s.split(",").map(&:strip).reject(&:blank?).uniq
  end

  def auto_pick_skip_labels_param_submitted?
    raw = params[:project]
    raw&.key?(:auto_pick_skip_labels) ||
      raw&.key?(:auto_pick_skip_labels_csv) ||
      raw&.key?(:auto_pick_skip_labels_override)
  end

  def parse_auto_pick_skip_labels
    raw = params.require(:project)
    return AutoPickSkipLabels.normalize(raw[:auto_pick_skip_labels]) if raw.key?(:auto_pick_skip_labels)
    return nil unless ActiveModel::Type::Boolean.new.cast(raw[:auto_pick_skip_labels_override])

    AutoPickSkipLabels.parse_csv(raw[:auto_pick_skip_labels_csv])
  end

  def load_screenshot_settings_context
    @screenshot_settings = @project.effective_screenshot_settings
    @screenshot_status = @project.effective_screenshot_status
    @screenshot_service_options = policy_scope(ServiceContainer).order(:name)
    @screenshot_repo_config_result ||= load_screenshot_repo_config_result
    @screenshot_preview_config = @project.screenshot_preview_config(
      repo_config: @screenshot_repo_config_result.config
    )
    @screenshot_conflicts = @project.screenshot_config_conflicts(
      repo_config: @screenshot_repo_config_result.config
    )
  end

  def load_screenshot_repo_config_result
    Projects::Screenshots::RepoConfig.call(
      project: @project,
      path: @project.effective_screenshot_settings["config_path"]
    )
  rescue StandardError => e
    Rails.logger.warn(
      message: "projects.screenshots.repo_config_load_failed",
      project_id: @project.id,
      error: e.message
    )
    Projects::Screenshots::RepoConfig::Result.new(
      config: {},
      content: nil,
      error: "Could not load repository screenshot config: #{e.message}"
    )
  end

  def save_project_with_cached_data
    @project.name = @project.name.presence || @project.repo

    if @project.save
      TenantConfigurations::ApplyProjectDefaults.call(@project)
      ensure_labels_best_effort(@project)
      audit_event("project.created", metadata: { name: @project.name, github_url: "https://github.com/#{@project.full_name}" })
      redirect_to @project, notice: "Project was successfully added."
    else
      render :new, status: :unprocessable_content
    end
  end

  def fetch_github_metadata
    client = @project.client
    repo_data = client.repository("#{@project.owner}/#{@project.repo}")

    @project.github_id = repo_data.id
    @project.name = @project.name.presence || repo_data.name
    @project.default_branch = repo_data.default_branch

    if @project.save
      TenantConfigurations::ApplyProjectDefaults.call(@project)
      ensure_labels_best_effort(@project)
      audit_event("project.created", metadata: { name: @project.name, github_url: "https://github.com/#{@project.full_name}" })
      redirect_to @project, notice: "Project was successfully added."
    else
      render :new, status: :unprocessable_content
    end
  rescue GithubClient::NotFoundError
    @project.errors.add(:base, "Repository not found. Please check the owner and repository name.")
    render :new, status: :unprocessable_content
  rescue GithubClient::AuthenticationError => e
    @project.errors.add(:base, "GitHub authentication failed: #{e.message}")
    render :new, status: :unprocessable_content
  rescue GithubClient::RateLimitError
    @project.errors.add(:base, "GitHub API rate limit exceeded. Please try again later.")
    render :new, status: :unprocessable_content
  rescue GithubClient::ApiError => e
    @project.errors.add(:base, "GitHub API error: #{e.message}")
    render :new, status: :unprocessable_content
  rescue GithubClient::Error => e
    @project.errors.add(:base, "Unexpected GitHub error: #{e.message}")
    render :new, status: :unprocessable_content
  end
end
