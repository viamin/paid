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
    @projects_covered_by_github_app = current_account.projects.select(:id, :owner, :repo).to_a.count do |project|
      @active_github_installations.any? { |inst| inst.covers_repository?(project.full_name) }
    end
  end

  def new
  end
end
