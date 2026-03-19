# frozen_string_literal: true

class QualityDashboardsController < ApplicationController
  def show
    @project = policy_scope(Project).find_by(id: params[:project_id]) || policy_scope(Project).first
    @projects = policy_scope(Project).order(:name)
    @stats = @project ? QualityMetrics::DashboardStats.call(project: @project) : nil
  end
end
