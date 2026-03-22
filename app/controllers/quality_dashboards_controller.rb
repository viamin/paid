# frozen_string_literal: true

class QualityDashboardsController < ApplicationController
  def show
    projects = policy_scope(Project).order(:name)
    @project = projects.find_by(id: params[:project_id]) || projects.first
    @projects = projects

    authorize(@project || Project, :show?)
    @stats = @project ? QualityMetrics::DashboardStats.call(project: @project) : nil
  end
end
