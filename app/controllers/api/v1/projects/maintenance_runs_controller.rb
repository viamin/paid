# frozen_string_literal: true

module Api
  module V1
    module Projects
      # Authenticated maintenance-run API. It uses the same admission and
      # cancellation boundaries as the web and MCP surfaces.
      # @spec MAINT-002 @spec MAINT-010 @spec MAINT-016 @spec MAINT-017
      class MaintenanceRunsController < BaseController
        include AgentRunCancellable
        include AuditLogging

        before_action -> { require_scope!(:inbox) }
        before_action :set_project
        before_action :set_run, only: %i[show cancel]

        def create
          authorize @project, :run_agent?
          run = MaintenanceRuns::Start.call(project: @project, actor: current_user, **start_attributes)
          audit_event("agent_run.created", subject: run, metadata: { agent_run_id: run.id, project_name: @project.name, goal: run.goal })
          render json: run_payload(run), status: :created
        rescue MaintenanceRuns::Start::FeatureDisabledError,
               MaintenanceRuns::Start::MissingObjectiveError,
               MaintenanceRuns::Start::UnknownObjectiveError,
               MaintenanceRuns::Start::BudgetExceededError,
               MaintenanceRuns::Start::NoRunnableRunnerError,
               MaintenanceRuns::Start::RevisionUnavailableError => error
          render_error(:unprocessable_content, :maintenance_run_unavailable, error.message)
        end

        def show
          authorize @run, :show?
          render json: run_payload(@run)
        end

        def cancel
          authorize @run, :cancel?
          result = cancel_agent_run_result(@run)
          render json: run_payload(@run.reload).merge(message: result.message)
        end

        private

        def set_project
          @project = policy_scope(Project).find(params[:project_id])
        end

        def set_run
          @run = @project.agent_runs.where(goal: AgentRun::MAINTENANCE_GOAL).find(params[:id])
        end

        def start_attributes
          params.permit(:objective, :guidance, :scope).to_h.symbolize_keys
        end

        def run_payload(run)
          {
            id: run.id,
            project_id: run.project_id,
            issue_id: nil,
            status: run.status,
            goal: run.goal,
            scope: run.maintenance_scope,
            scope_kind: run.maintenance_scope_kind,
            created_at: run.created_at,
            maintenance: {
              objective: run.maintenance_objective,
              recipe_version: run.maintenance_recipe_version,
              scope: run.maintenance_scope,
              scope_kind: run.maintenance_scope_kind,
              guidance: run.maintenance_guidance,
              pinned_revision: run.maintenance_pinned_revision,
              limits: run.maintenance_limits,
              report_only: true
            }
          }
        end
      end
    end
  end
end
