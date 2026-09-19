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
      authorize @project, :update?
      revision.approve!(current_user)
      redirect_to project_apple_verification_path(@project), notice: "Workflow revision approved."
    end

    def rerun
      authorize @project, :run_agent?
      source = attempt
      @project.apple_verification_attempts.create!(workflow_revision: source.workflow_revision, retry_of: source, queue_position: source.queue_position)
      redirect_to project_apple_verification_path(@project), notice: "Verification rerun queued."
    end

    def cancel
      authorize @project, :run_agent?
      attempt.update!(state: "cancelled", failure_class: "cancellation", cancelled_at: Time.current)
      redirect_to project_apple_verification_path(@project), notice: "Verification cancelled."
    end

    def waive
      authorize @project, :update?
      attempt.update!(state: "waived", waived_by: current_user, waiver_reason: params.require(:reason))
      redirect_to project_apple_verification_path(@project), notice: "Attempt waived."
    end

    def destroy_retained_vm
      authorize @project, :update?
      attempt.update!(retained_vm_destroyed_at: Time.current)
      redirect_to project_apple_verification_path(@project), notice: "Retained VM destruction recorded."
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def require_feature
      return if FeatureFlags.enabled?(:apple_verification_workers, project: @project)

      raise Pundit::NotAuthorizedError
    end

    def revision
      @project.apple_verification_workflow_revisions.find(params.require(:revision_id))
    end

    def attempt
      @project.apple_verification_attempts.find(params.require(:attempt_id))
    end

    def settings_params
      params.require(:project).permit(:mode, profiles: {}).to_h.deep_stringify_keys
    end
  end
end
