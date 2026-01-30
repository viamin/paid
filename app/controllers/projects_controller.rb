# frozen_string_literal: true

class ProjectsController < ApplicationController
  before_action :set_project, only: [ :show, :edit, :update, :destroy ]
  skip_after_action :verify_authorized, only: :index

  def index
    @projects = policy_scope(Project).includes(:github_token, :agent_runs).order(created_at: :desc)
  end

  def show
    authorize @project
    @recent_agent_runs = @project.agent_runs.recent.limit(10)
  end

  def new
    @project = current_account.projects.build
    @github_tokens = policy_scope(GithubToken).where(revoked_at: nil)
    authorize @project
  end

  def create
    @project = current_account.projects.build(project_params)
    @project.created_by = current_user
    authorize @project

    @github_tokens = policy_scope(GithubToken).where(revoked_at: nil)

    if @project.github_token.blank?
      @project.errors.add(:github_token_id, "must be selected")
      return render :new, status: :unprocessable_entity
    end

    fetch_github_metadata
  end

  def edit
    authorize @project
    @github_tokens = policy_scope(GithubToken).where(revoked_at: nil)
  end

  def update
    authorize @project
    @github_tokens = policy_scope(GithubToken).where(revoked_at: nil)

    if @project.update(project_params)
      redirect_to @project, notice: "Project was successfully updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    authorize @project
    @project.destroy!
    redirect_to projects_path, notice: "Project was successfully deleted."
  end

  private

  def set_project
    @project = policy_scope(Project).find(params[:id])
  end

  def project_params
    params.require(:project).permit(:github_token_id, :owner, :repo, :name, :active, :poll_interval_seconds)
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
      render :new, status: :unprocessable_entity
    end
  rescue GithubClient::NotFoundError
    @project.errors.add(:base, "Repository not found. Please check the owner and repository name.")
    render :new, status: :unprocessable_entity
  rescue GithubClient::AuthenticationError => e
    @project.errors.add(:base, "GitHub authentication failed: #{e.message}")
    render :new, status: :unprocessable_entity
  rescue GithubClient::RateLimitError
    @project.errors.add(:base, "GitHub API rate limit exceeded. Please try again later.")
    render :new, status: :unprocessable_entity
  rescue GithubClient::ApiError => e
    @project.errors.add(:base, "GitHub API error: #{e.message}")
    render :new, status: :unprocessable_entity
  end
end
