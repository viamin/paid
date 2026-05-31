# frozen_string_literal: true

class IntegrationsController < ApplicationController
  skip_after_action :verify_authorized
  skip_after_action :verify_policy_scoped

  def index
    @sections = Integrations::Hub.sections_for(current_account, current_user)
    @github_installations = current_account.github_installations.order(created_at: :desc).load
    @active_github_installations = @github_installations.select(&:active?)
    active_installation_ids = @active_github_installations.map(&:id)
    @projects_with_github_app = current_account.projects.where(github_installation_id: active_installation_ids).count
    @projects_covered_by_github_app = current_account.projects.select(:id, :owner, :repo, :github_installation_id).count do |project|
      project.paid_agents_installation(installations: @active_github_installations).present?
    end
  end

  def new
  end
end
