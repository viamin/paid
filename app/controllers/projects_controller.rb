# frozen_string_literal: true

class ProjectsController < ApplicationController
  before_action :set_project, only: [ :show, :edit, :update, :destroy ]
  skip_after_action :verify_authorized, only: :index

  NULLS_LAST_SORT_ATTRIBUTES = %w[last_agent_run_at last_github_activity_at].freeze

  def index
    base_scope = policy_scope(Project).includes(:github_token, :agent_runs)
    @q = base_scope.ransack(params[:q])
    @q.sorts = "created_at desc" if @q.sorts.empty?
    @projects = apply_nulls_last_ordering(@q.result)
  end

  def show
    authorize @project
    @recent_agent_runs = @project.agent_runs.recent.limit(10)
    open_items = @project.issues.where(github_state: "open").order(github_number: :desc)
    @issues = open_items.issues_only.limit(25)
    @pull_requests = open_items.pull_requests_only.limit(25)
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
  end

  def update
    authorize @project
    @github_tokens = policy_scope(GithubToken).where(revoked_at: nil)

    update_params = project_params
    update_params = update_params.merge(allowed_github_usernames: parse_usernames_csv) if params.dig(:project, :allowed_github_usernames_csv)

    if @project.update(update_params)
      redirect_to @project, notice: "Project was successfully updated."
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    authorize @project
    @project.destroy!
    redirect_to projects_path, notice: "Project was successfully deleted."
  end

  private

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
      :owner_reviewer_login, :merge_method, :max_draft_review_rounds,
      allowed_github_usernames: [])
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
