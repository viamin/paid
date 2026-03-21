# frozen_string_literal: true

class QualityDashboardsController < ApplicationController
  skip_after_action :verify_authorized

  def show
    projects = policy_scope(Project).order(:name)
    @project = projects.find_by(id: params[:project_id]) || projects.first
    @projects = projects
    @stats = @project ? QualityMetrics::DashboardStats.call(project: @project) : nil
  end
end
