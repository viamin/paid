# frozen_string_literal: true

class GithubInstallationsController < ApplicationController
  before_action :set_github_installation, only: :repositories

  def repositories
    authorize @github_installation, :show?

    existing_github_ids = current_account.projects.pluck(:github_id)
    available_repos = normalized_repositories.reject { |repo| existing_github_ids.include?(repo["id"]) }

    render json: available_repos
  end

  private

  def set_github_installation
    @github_installation = policy_scope(GithubInstallation).find(params[:id])
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
