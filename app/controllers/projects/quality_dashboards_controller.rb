# frozen_string_literal: true

module Projects
  class QualityDashboardsController < ApplicationController
    before_action :set_project

    def show
      authorize @project, :show?
      @stats = QualityMetrics::DashboardStats.call(project: @project)
      @quality_alerts = Notification
        .where(account: @project.account, source: QualityAlerts::CheckGate::NOTIFICATION_SOURCE, subject: @project)
        .visible
        .recent
        .limit(10)
      @quality_gate_settings = @project.effective_quality_gate_settings
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end
  end
end
