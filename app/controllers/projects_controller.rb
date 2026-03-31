# frozen_string_literal: true

class ProjectsController < ApplicationController
  before_action :set_project, only: [ :show, :edit, :update, :destroy, :toggle_auto_pick, :toggle_auto_merge, :detect_services ]
  skip_after_action :verify_authorized, only: :index

  NULLS_LAST_SORT_ATTRIBUTES = %w[last_agent_run_at last_github_activity_at].freeze
  AUTO_PICK_PARTIALS = {
    "index" => "projects/auto_pick_toggle_index"
  }.freeze
  AUTO_MERGE_PARTIALS = {
    "index" => "projects/auto_merge_toggle_index"
  }.freeze

  def index
    base_scope = policy_scope(Project).includes(:github_token, :agent_runs)
    @q = base_scope.ransack(params[:q])
    @q.sorts = "last_agent_run_at desc" if @q.sorts.empty?
    @projects = apply_nulls_last_ordering(@q.result)
  end

  def show
    authorize @project
    @recent_agent_runs = @project.agent_runs.recent.limit(10)
    open_items = @project.issues.where(github_state: "open").order(github_number: :desc)
    @issues = open_items.issues_only.includes(:sub_issues).limit(25)
    @auto_pickable_issue_ids = @project.auto_pick_enabled? ? Issues::AutoPick.eligible_issue_ids(@issues) : Set.new
    @pull_requests = open_items.pull_requests_only.limit(25)
    @pr_numbers_with_queued_auto_continue = @project.pr_numbers_with_queued_auto_continue
    @pr_numbers_with_active_runs = @project.pr_numbers_with_active_runs
    @cost_budgets = @project.cost_budgets.load
    @quality_summary = QualityMetrics::DashboardStats.overview(project: @project)
    @collector_runs = CollectorRun
      .joins(:project_version)
      .where(project_versions: { project_id: @project.id })
      .includes(:project_version)
      .order(created_at: :desc)
      .limit(20)
  end

  def new
    @project = current_account.projects.build
    @github_tokens = policy_scope(GithubToken).where(revoked_at: nil)
    authorize @project
  end

  def create
    @project = current_account.projects.build(project_params)
    @project.created_by = current_user
    @project.allowed_github_usernames = [ @project.owner ] if @project.allowed_github_usernames.blank?
    authorize @project

    @github_tokens = policy_scope(GithubToken).where(revoked_at: nil)

    if @project.github_token.blank?
      @project.errors.add(:github_token_id, "must be selected")
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
    @available_service_containers = ServiceContainer.where.not(id: @project.service_container_ids).order(:name)
  end

  def update
    authorize @project
    @github_tokens = policy_scope(GithubToken).where(revoked_at: nil)

    update_params = project_params
    update_params = update_params.merge(allowed_github_usernames: parse_usernames_csv) if params.dig(:project, :allowed_github_usernames_csv)
    update_params = update_params.merge(review_settings: build_review_settings) if params.dig(:project, :review_settings)

    if @project.update(update_params)
      redirect_to @project, notice: "Project was successfully updated."
    else
      @available_service_containers = ServiceContainer.where.not(id: @project.service_container_ids).order(:name)
      render :edit, status: :unprocessable_content
    end
  end

  def toggle_auto_pick
    toggle_automation(:auto_pick, AUTO_PICK_PARTIALS)
  end

  def toggle_auto_merge
    toggle_automation(:auto_merge, AUTO_MERGE_PARTIALS)
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

  def destroy
    authorize @project

    if params[:name_confirmation] != @project.name
      redirect_to edit_project_path(@project), alert: "Project name does not match. Please type the exact project name to confirm deletion."
      return
    end

    @project.destroy!
    redirect_to projects_path, notice: "Project was successfully deleted."
  end

  private

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

  def set_project
    @project = policy_scope(Project).includes(:github_token, :created_by).find(params[:id])
  end

  def project_params
    params.require(:project).permit(:github_token_id, :owner, :repo, :name, :active,
      :poll_interval_seconds, :github_id, :default_branch,
      :owner_reviewer_login, :merge_method, :max_draft_review_rounds, :auto_pick_enabled, :auto_merge_enabled,
      :auto_fix_merge_conflicts, :generated_label_name, :automation_label_name,
      :auto_add_labels_enabled, :automation_on_label_enabled,
      allowed_github_usernames: [])
  end

  TERMINATION_KEYS = %i[max_review_rounds stop_when_no_comments quality_threshold timeout_minutes].freeze

  def build_review_settings
    termination_permit = { termination: TERMINATION_KEYS }
    rs = params.require(:project).permit(
      review_settings: [
        :enabled, :wait_for_reviews,
        { methods: {
          copilot: [ :enabled, termination_permit ],
          paid_agent: [ :enabled, termination_permit ],
          ci_action: [ :enabled, :action_name, termination_permit ],
          manual: [ :enabled, termination_permit ]
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

    if settings["methods"].is_a?(Hash)
      settings["methods"].each_value do |config|
        next unless config.is_a?(Hash)

        config["enabled"] = ActiveModel::Type::Boolean.new.cast(config["enabled"]) if config.key?("enabled")
        next unless config["termination"].is_a?(Hash)

        term = config["termination"]
        term["max_review_rounds"] = term["max_review_rounds"].present? ? term["max_review_rounds"].to_i : nil
        term["timeout_minutes"] = term["timeout_minutes"].present? ? term["timeout_minutes"].to_i : nil
        term["stop_when_no_comments"] = ActiveModel::Type::Boolean.new.cast(term["stop_when_no_comments"]) if term.key?("stop_when_no_comments")
        term["quality_threshold"] = term["quality_threshold"].presence
      end
    end

    settings
  end

  def parse_usernames_csv
    params.dig(:project, :allowed_github_usernames_csv).to_s.split(",").map(&:strip).reject(&:blank?).uniq
  end

  def save_project_with_cached_data
    @project.name = @project.name.presence || @project.repo

    if @project.save
      redirect_to @project, notice: "Project was successfully added."
    else
      render :new, status: :unprocessable_content
    end
  end

  def fetch_github_metadata
    client = @project.github_token.client
    repo_data = client.repository("#{@project.owner}/#{@project.repo}")

    @project.github_id = repo_data.id
    @project.name = @project.name.presence || repo_data.name
    @project.default_branch = repo_data.default_branch

    if @project.save
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
