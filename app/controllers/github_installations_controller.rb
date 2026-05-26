# frozen_string_literal: true

class GithubInstallationsController < ApplicationController
  include AuditLogging

  before_action :set_github_installation, only: [ :repositories, :show, :check_access ]
  before_action :set_github_installation_for_migration, only: :migrate_projects
  before_action :set_github_installation_for_token_migration, only: :migrate_from_token

  # GET /github_installations/:id/repositories
  # Returns repositories available for project creation
  def repositories
    authorize @github_installation, :show?

    existing_github_ids = current_account.projects.pluck(:github_id)
    available_repos = normalized_repositories.reject { |repo| existing_github_ids.include?(repo["id"]) }

    render json: available_repos
  end

  # GET /github_installations
  # List all GitHub App installations for the current account
  def index
    @github_installations = policy_scope(GithubInstallation).order(created_at: :desc)
    authorize GithubInstallation, :index?
  end

  # GET /github_installations/:id
  # Show details of a specific installation
  def show
    authorize @github_installation, :show?

    @projects_using_installation = @github_installation.projects.includes(:created_by).order(created_at: :desc)
    @accessible_repos_count = @github_installation.accessible_repositories.count
  end

  # GET /github_installations/:id/migrate
  # Show migration form for a specific installation
  def migrate_projects
    authorize @github_installation, :show?

    @github_tokens = current_account.github_tokens.active.includes(:created_by).order(created_at: :desc)
    @projects = current_account.projects.where(github_token_id: @github_tokens.pluck(:id)).order(:name)
    @installation_repos = normalized_repositories

    # Check which repos are accessible
    accessible_repo_ids = @installation_repos.map { |r| r["id"] }.to_set
    @project_access_status = @projects.each_with_object({}) do |project, hash|
      hash[project.id] = accessible_repo_ids.include?(project.github_id)
    end
  end

  # POST /github_installations/:id/migrate
  # Migrate projects from PAT to GitHub App
  def migrate_from_token
    authorize @github_installation, :show?

    github_token = current_account.github_tokens.find_by(id: params[:github_token_id])
    unless github_token
      redirect_to migrate_project_github_installation_path(@github_installation),
        alert: "GitHub token not found"
      return
    end

    result = Github::MigrationService.migrate_from_token(
      github_token: github_token,
      github_installation: @github_installation,
      actor: current_user
    )

    if result.failed.zero?
      audit_event("github_app.migration.completed",
        metadata: {
          token_name: github_token.name,
          installation_id: @github_installation.id,
          total_migrated: result.successful
        })
      redirect_to @github_installation,
        notice: "Successfully migrated #{result.successful} project(s) to GitHub App"
    else
      redirect_to migrate_project_github_installation_path(@github_installation),
        alert: "Migration completed with #{result.failed} failure(s). #{result.successful} succeeded."
    end
  end

  # POST /github_installations/:id/check_access
  # Check repository accessibility via installation
  def check_access
    authorize @github_installation, :show?

    github_token_id = params[:github_token_id]
    github_token = current_account.github_tokens.find_by(id: github_token_id) if github_token_id.present?

    unless github_token
      render json: { error: "GitHub token not found" }, status: :not_found
      return
    end

    accessibility = Github::MigrationService.check_accessibility(
      github_token: github_token,
      github_installation: @github_installation
    )

    render json: {
      github_installation_id: @github_installation.id,
      github_token_id: github_token.id,
      repositories: accessibility
    }
  end

  private

  def set_github_installation
    @github_installation = policy_scope(GithubInstallation).find(params[:id])
  end

  def set_github_installation_for_migration
    set_github_installation
  end

  def set_github_installation_for_token_migration
    set_github_installation
  end

  def normalized_repositories
    Array(@github_installation.accessible_repositories).filter_map do |repo|
      data = repo.with_indifferent_access
      full_name = data[:full_name].presence
      next if full_name.blank?

      owner, name = full_name.split("/", 2)

      {
        "id" => data[:id],
        "full_name" => full_name,
        "name" => data[:name].presence || name,
        "owner" => data[:owner].presence || owner,
        "default_branch" => data[:default_branch],
        "private" => data[:private] || false
      }
    end
  end
end
