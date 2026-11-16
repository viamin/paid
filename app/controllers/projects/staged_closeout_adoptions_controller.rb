# frozen_string_literal: true

module Projects
  # Operator/API surface for reviewed staged-closeout eligibility. It never
  # dispatches a check; automatic scheduling belongs to #5074.
  # @spec STAGED-CLOSEOUT-ADOPTION-001 STAGED-CLOSEOUT-ADOPTION-002
  class StagedCloseoutAdoptionsController < ApplicationController
    before_action :set_project

    def show
      authorize @project, :update?
      render json: payload
    end

    def update
      authorize @project, :update?
      enrollment = StagedCloseoutAdoption::Enroll.call(project: @project, actor: current_user, enabled: params.require(:enabled))
      render json: payload.merge(enrollment: enrollment.slice(:enabled, :reviewed_at, :revision))
    rescue StagedCloseoutAdoption::Error => error
      render json: { error: error.message }, status: :unprocessable_entity
    end

    def create_mapping
      authorize @project, :update?
      issue = @project.issues.find(params.require(:issue_id))
      mapping = StagedCloseoutAdoption::Mappings.approve(project: @project, actor: current_user, issue:, attributes: mapping_params)
      render json: { mapping: mapping.slice(*mapping_fields) }, status: :created
    rescue StagedCloseoutAdoption::Error, ActiveRecord::RecordInvalid => error
      render json: { error: error.message }, status: :unprocessable_entity
    end

    def revoke_mapping
      authorize @project, :update?
      mapping = @project.staged_closeout_mappings.find(params[:id])
      StagedCloseoutAdoption::Mappings.revoke(mapping:, project: @project, actor: current_user, issue: mapping.issue, attributes: {}).then do |record|
        render json: { mapping: record.slice(*mapping_fields) }
      end
    rescue StagedCloseoutAdoption::Error => error
      render json: { error: error.message }, status: :unprocessable_entity
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def payload
      { enrollment: @project.staged_closeout_enrollment&.slice(:enabled, :reviewed_at, :revision) || { enabled: false },
        mappings: @project.staged_closeout_mappings.order(:issue_id, :criterion_key, :revision).map { |mapping| mapping.slice(*mapping_fields) },
        automatic_run_reason: @project.staged_closeout_enrollment&.enabled? ? "no_approved_mapping_or_scheduler" : "project_not_enrolled" }
    end

    def mapping_fields
      %w[id issue_id criterion_key stage phase target_shape execution_path target_key target_version target_digest environment_class freshness_seconds retry_policy status revision reviewed_at invalidated_at invalidation_reason]
    end

    def mapping_params
      params.require(:mapping).permit(:criterion_key, :stage, :phase, :target_shape, :execution_path, :target_key,
        :environment_class, :freshness_seconds, retry_policy: {}).to_h
    end
  end
end
