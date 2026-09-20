# frozen_string_literal: true

module Projects
  # @spec APPLE-VERIFY-001
  class AppleVerificationsController < ApplicationController
    before_action :set_project
    before_action :require_feature

    def show
      authorize @project, :show?
      @revisions = @project.apple_verification_workflow_revisions.includes(:apple_worker_profile).order(created_at: :desc)
      @attempts = @project.apple_verification_attempts.includes(:apple_verification_workflow_revision, :apple_verification_artifacts).order(created_at: :desc)
    end

    def compare
      authorize @project, :show?
      @revision = revision
      @comparison_revision = comparison_revision
      @differences = @revision.differences_from(@comparison_revision)
    end

    def artifact
      authorize @project, :show?
      redirect_to ArtifactStorage.new.signed_url(verification_artifact.storage_key), allow_other_host: true
    end

    def update
      authorize @project, :update?
      if @project.update(apple_verification_mode: settings_params[:mode])
        redirect_to project_apple_verification_path(@project), notice: "Apple verification settings updated."
      else
        redirect_to project_apple_verification_path(@project), alert: @project.errors.full_messages.to_sentence
      end
    end

    def approve
      authorize @project, :manage_apple_verifications?
      revision.approve!(actor: current_user)
      redirect_to project_apple_verification_path(@project), notice: "Workflow revision approved."
    rescue ArgumentError => e
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

    def revision
      @project.apple_verification_workflow_revisions.find(params.require(:revision_id))
    end

    def comparison_revision
      @project.apple_verification_workflow_revisions.find(params.require(:compare_to_id))
    end

    def verification_artifact
      AppleVerificationArtifact.joins(:apple_verification_attempt)
        .where(apple_verification_attempts: { project_id: @project.id })
        .find(params.require(:artifact_id))
    end

    def settings_params
      params.require(:project).permit(:mode)
    end
  end
end
