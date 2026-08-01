# frozen_string_literal: true

module Projects
  class HealthCheckController < ApplicationController
    SEVERITY_CIRCLE = {
      error: "bg-red-100",
      warning: "bg-amber-100",
      info: "bg-blue-100"
    }.freeze
    SEVERITY_ICON = {
      error: "text-red-600",
      warning: "text-amber-600",
      info: "text-blue-600"
    }.freeze
    SUMMARY_BADGE = {
      healthy: "bg-green-50 text-green-700 ring-green-200",
      warning: "bg-amber-50 text-amber-800 ring-amber-200",
      error: "bg-red-50 text-red-700 ring-red-200"
    }.freeze
    SCOPE_LABELS = {
      project: "Project",
      runner: "Runners",
      user: "User"
    }.freeze

    helper_method :severity_circle_class, :severity_icon_class, :summary_badge_class, :scope_label

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

    def severity_circle_class(severity)
      SEVERITY_CIRCLE.fetch(severity.to_sym, "bg-gray-100")
    end

    def severity_icon_class(severity)
      SEVERITY_ICON.fetch(severity.to_sym, "text-gray-600")
    end

    def summary_badge_class(result)
      return SUMMARY_BADGE[:healthy] if result.nil? || result.healthy?
      return SUMMARY_BADGE[:warning] if result.warnings?

      SUMMARY_BADGE[:error]
    end

    def scope_label(scope)
      SCOPE_LABELS.fetch(scope.to_sym, scope.to_s.humanize)
    end
  end
end
