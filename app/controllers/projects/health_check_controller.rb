# frozen_string_literal: true

module Projects
  class HealthCheckController < ApplicationController
    before_action :set_project

    def show
      authorize @project, :show?
      @result = HealthChecks::Cache.read(@project)
    end

    def refresh
      authorize @project, :show?
      ProjectHealthCheckJob.perform_later(@project.id)
      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to project_health_check_path(@project), notice: "Re-running health checks\u2026" }
      end
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end
  end
end
