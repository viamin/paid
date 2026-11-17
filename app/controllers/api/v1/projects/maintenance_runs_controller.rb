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

        def types
          authorize @project, :run_agent?
          return render_maintenance_runs_disabled unless FeatureFlags.enabled?(:maintenance_runs, project: @project)

          render json: { types: MaintenanceRuns::OptimizationTypes.menu }
        end

        def create
          authorize @project, :run_agent?
          run = MaintenanceRuns::Start.call(project: @project, actor: current_user, **start_attributes)
          audit_event("agent_run.created", subject: run, metadata: { agent_run_id: run.id, project_name: @project.name, goal: run.goal })
          render json: run_payload(run), status: :created
        rescue MaintenanceRuns::Start::FeatureDisabledError,
               MaintenanceRuns::Start::MissingObjectiveError,
               MaintenanceRuns::Start::InvalidTypeError,
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
          params.permit(:objective, :type, :guidance, :scope).to_h.symbolize_keys
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
              type: run.maintenance_type,
              objective: run.maintenance_objective,
              recipe_version: run.maintenance_recipe_version,
              scope: run.maintenance_scope,
              scope_kind: run.maintenance_scope_kind,
              guidance: run.maintenance_guidance,
              pinned_revision: run.maintenance_pinned_revision,
              limits: run.maintenance_limits,
              report_only: true,
              report: report_payload(run.maintenance_report)
            }
          }
        end

        # @spec MAINT-016 — report inspection shares the already-authorized
        # run surface and therefore cannot widen tenant access.
        def report_payload(report)
          return nil unless report

          {
            outcome: report.outcome,
            resolved_scope: report.resolved_scope,
            exclusions: report.exclusions,
            completed_checks: report.completed_checks,
            incomplete_checks: report.incomplete_checks,
            evidence: report.evidence,
            findings: report.finding_occurrences.includes(:maintenance_finding).map do |occurrence|
              {
                id: occurrence.id, claim: occurrence.claim, category: occurrence.category, symbols: occurrence.symbols,
                locations: occurrence.locations, supporting_evidence: occurrence.supporting_evidence,
                contrary_evidence: occurrence.contrary_evidence, analyzer_provenance: occurrence.analyzer_provenance,
                raw_tool_confidence: occurrence.raw_tool_confidence,
                agent_assessment: occurrence.agent_assessment, proposed_action: occurrence.proposed_action,
                validation_plan: occurrence.validation_plan, verification_disposition: occurrence.verification_disposition,
                observed_status: occurrence.observed_status, dismissal_reason: occurrence.maintenance_finding.dismissal_reason,
                status: occurrence.maintenance_finding.status, reassessment_required: occurrence.maintenance_finding.reassessment_required
              }
            end
          }
        end

        def render_maintenance_runs_disabled
          render_error(
            :unprocessable_content,
            :maintenance_run_unavailable,
            "Maintenance runs are not enabled for this project's tenant (maintenance_runs feature flag)."
          )
        end
      end
    end
  end
end
