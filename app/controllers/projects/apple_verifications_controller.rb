# frozen_string_literal: true

module Projects
  # @spec APPLE-VERIFY-001
  class AppleVerificationsController < ApplicationController
    before_action :set_project
    before_action :require_feature

    def show
      authorize @project, :show?
      @revisions = @project.apple_verification_workflow_revisions.order(created_at: :desc)
      @attempts = @project.apple_verification_attempts.includes(:workflow_revision, :artifacts, :retry_of).order(created_at: :desc)
    end

    def update
      authorize @project, :update?
      @project.update!(apple_verification_settings: @project.apple_verification_settings.merge(settings_params))
      redirect_to project_apple_verification_path(@project), notice: "Apple verification settings updated."
    end

    def approve
      authorize @project, :manage_apple_verifications?
      revision.approve!(current_user)
      redirect_to project_apple_verification_path(@project), notice: "Workflow revision approved."
    rescue AppleVerificationWorkflowRevision::InvalidTransitionError => e
      redirect_to project_apple_verification_path(@project), alert: e.message
    end

    def rerun
      authorize @project, :run_agent?
      require_on_demand_execution
      source = attempt
      @project.apple_verification_attempts.create!(workflow_revision: source.workflow_revision, retry_of: source, queue_position: source.queue_position)
      redirect_to project_apple_verification_path(@project), notice: "Verification rerun queued."
    end

    def cancel
      authorize @project, :run_agent?
      attempt.cancel!
      redirect_to project_apple_verification_path(@project), notice: "Verification cancelled."
    rescue AppleVerificationAttempt::InvalidTransitionError => e
      redirect_to project_apple_verification_path(@project), alert: e.message
    end

    def waive
      authorize @project, :manage_apple_verifications?
      attempt.waive!(current_user, params.require(:reason))
      redirect_to project_apple_verification_path(@project), notice: "Attempt waived."
    rescue AppleVerificationAttempt::InvalidTransitionError => e
      redirect_to project_apple_verification_path(@project), alert: e.message
    end

    def destroy_retained_vm
      authorize @project, :manage_apple_verifications?
      attempt.record_retained_vm_destruction!
      redirect_to project_apple_verification_path(@project), notice: "Retained VM destruction recorded."
    rescue AppleVerificationAttempt::InvalidTransitionError => e
      redirect_to project_apple_verification_path(@project), alert: e.message
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def require_feature
      return if FeatureFlags.enabled?(:apple_verification_workers, project: @project)

      raise Pundit::NotAuthorizedError
    end

    def require_on_demand_execution
      return if @project.apple_verification_on_demand?

      raise Pundit::NotAuthorizedError
    end

    def revision
      @project.apple_verification_workflow_revisions.find(params.require(:revision_id))
    end

    def attempt
      @project.apple_verification_attempts.find(params.require(:attempt_id))
    end

    def settings_params
      params.require(:project).permit(:mode).to_h.deep_stringify_keys
    end
  end
end
