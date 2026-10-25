# frozen_string_literal: true

module Projects
  # Capability-aware prerequisite evidence validation surface: one controller
  # serving the same contract to the Inbox/UI and JSON API consumers
  # (capabilities inspection, bounded start, progress/evidence read,
  # cancellation, idempotent retry).
  #
  # @spec PREREQ-EXEC-005 @spec PREREQ-EXEC-015 @spec PREREQ-EXEC-016
  class PrerequisiteValidationsController < ApplicationController
    before_action :set_project
    before_action :set_validation, only: [ :show, :cancel, :retry ]

    # GET /projects/:project_id/prerequisite_validations/capabilities
    # @spec PREREQ-EXEC-001 @spec PREREQ-EXEC-016
    def capabilities
      authorize @project, :show?
      report = PrerequisiteExecutions::Capabilities.call(
        project: @project,
        tool_image: params[:tool_image].presence
      )
      render json: report.to_h
    end

    # POST /projects/:project_id/prerequisite_validations
    # @spec PREREQ-EXEC-006
    def create
      authorize @project, :run_agent?

      result = PrerequisiteExecutions::Start.call(
        project: @project,
        issue: resolve_issue,
        actor: current_user,
        branch: params[:branch].presence || @project.default_branch,
        native_command: params[:native_command],
        marketplace_entry_id: params[:marketplace_entry_id]
      )
      respond_with_result(result, notice: "Validation started. Evidence will appear here when the attempt finishes.")
    rescue PrerequisiteExecutions::Start::InvalidError => e
      respond_to do |format|
        format.html { redirect_to return_target_or_inbox, alert: e.message }
        format.json { render json: { error: e.message }, status: :unprocessable_entity }
      end
    end

    # GET /projects/:project_id/prerequisite_validations/:id
    # @spec PREREQ-EXEC-016
    def show
      authorize @project, :show?
      respond_to do |format|
        format.html
        format.json { render json: validation_payload }
      end
    end

    # POST /projects/:project_id/prerequisite_validations/:id/cancel
    # @spec PREREQ-EXEC-013
    def cancel
      authorize @project, :run_agent?
      result = PrerequisiteExecutions::Cancel.call(@validation)
      respond_with_result(result, notice: result.message)
    end

    # POST /projects/:project_id/prerequisite_validations/:id/retry
    # Idempotent: same-scope succeeded evidence is returned unchanged;
    # changed scope revalidates and marks prior evidence stale.
    # @spec PREREQ-EXEC-014
    def retry
      authorize @project, :run_agent?
      contract = @validation.contract
      result = PrerequisiteExecutions::Start.call(
        project: @project,
        issue: @validation.issue,
        actor: current_user,
        branch: contract["branch"],
        native_command: contract["native_command"],
        marketplace_entry_id: contract.dig("tool", "marketplace_entry_id")
      )
      respond_with_result(result, notice: "Validation retry evaluated.")
    rescue PrerequisiteExecutions::Start::InvalidError => e
      respond_to do |format|
        format.html { redirect_to return_target_or_inbox, alert: e.message }
        format.json { render json: { error: e.message }, status: :unprocessable_entity }
      end
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def set_validation
      @validation = @project.prerequisite_execution_validations.find(params[:id])
    end

    def resolve_issue
      return nil if params[:issue_id].blank?

      @project.issues.find(params[:issue_id])
    end

    def respond_with_result(result, notice:)
      respond_to do |format|
        format.html do
          flash_key = [ :unavailable, :already_terminal ].include?(result.outcome) ? :alert : :notice
          redirect_to redirect_target(result), flash_key => result.message.presence || notice
        end
        format.json { render json: validation_payload(result.validation) }
      end
    end

    def redirect_target(result)
      return return_target_or_inbox unless result.validation

      project_prerequisite_validation_path(@project, result.validation)
    end

    def return_target_or_inbox
      normalized_return_to(params[:return_to]) || inbox_path
    end

    def validation_payload(validation = @validation)
      {
        id: validation.id,
        status: validation.status,
        stale: validation.stale?,
        branch: validation.branch,
        scope_digest: validation.scope_digest,
        contract: validation.contract,
        capability_snapshot: validation.capability_snapshot,
        steps: validation.steps,
        evidence: validation.evidence,
        last_error: validation.last_error,
        missing_requirements: validation.missing_requirements,
        agent_run_id: validation.agent_run_id,
        issue_id: validation.issue_id,
        created_at: validation.created_at,
        started_at: validation.started_at,
        finished_at: validation.finished_at
      }
    end
  end
end
