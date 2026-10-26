# frozen_string_literal: true

module Projects
  class LayeredVerificationAuditsController < ApplicationController
    # @spec LAYERED-VERIFY-010 @spec LAYERED-VERIFY-012 @spec LAYERED-VERIFY-013
    before_action :set_project

    def new
      authorize @project, :manage_issues?
      LayeredVerification::AuditAccess.authorize!(user: current_user, project: @project)
      @preview = audit_request.preview
    rescue ArgumentError => error
      redirect_to project_path(@project), alert: error.message
    end

    def create
      authorize @project, :manage_issues?
      LayeredVerification::AuditAccess.authorize!(user: current_user, project: @project)
      run = audit_request.dispatch
      redirect_to project_agent_run_path(@project, run), notice: "Layered verification audit queued."
    rescue ArgumentError => error
      redirect_to new_project_layered_verification_audit_path(@project), alert: error.message
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def audit_request
      @audit_request ||= LayeredVerification::Audits::Request.new(
        project: @project, user: current_user, obligation_ids: params[:obligation_ids], budget: params[:budget],
        target_revision: params[:target_revision]
      )
    end
  end
end
