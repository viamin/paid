# frozen_string_literal: true

module Projects
  # Manual maintenance-run start surface (RDR-075 M01). Admission shares the
  # MaintenanceRuns::Start boundary with the MCP tool so the rollout guard and
  # objective rule are identical on every surface. Inspection and cancellation
  # reuse the shared agent-run show/cancel paths.
  # @spec MAINT-002 @spec MAINT-010 @spec MAINT-011
  class MaintenanceRunsController < ApplicationController
    include AuditLogging

    before_action :set_project

    def new
      authorize @project, :run_agent?
      ensure_maintenance_runs_enabled!
    end

    def create
      authorize @project, :run_agent?

      run = MaintenanceRuns::Start.call(
        project: @project,
        actor: current_user,
        objective: params[:objective].presence,
        guidance: params[:guidance]&.strip,
        scope: params[:scope]&.strip
      )
      audit_event("agent_run.created",
        metadata: { agent_run_id: run.id, project_name: @project.name, goal: run.goal })
      redirect_to project_agent_run_path(@project, run),
        notice: "Maintenance run queued. It will start automatically when a slot opens."
    rescue MaintenanceRuns::Start::FeatureDisabledError => e
      redirect_to project_path(@project), alert: e.message
    rescue MaintenanceRuns::Start::MissingObjectiveError,
           MaintenanceRuns::Start::UnknownObjectiveError => e
      redirect_to new_project_maintenance_run_path(@project), alert: e.message
    rescue MaintenanceRuns::Start::BudgetExceededError,
           MaintenanceRuns::Start::NoRunnableRunnerError => e
      redirect_to new_project_maintenance_run_path(@project), alert: e.message
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    # @spec MAINT-002 — the UI refuses admission identically while the guard
    # is off for the project's tenant.
    def ensure_maintenance_runs_enabled!
      return if FeatureFlags.enabled?(:maintenance_runs, project: @project)

      redirect_to project_path(@project),
        alert: "Maintenance runs are not enabled for this project's tenant (maintenance_runs feature flag)."
    end
  end
end
