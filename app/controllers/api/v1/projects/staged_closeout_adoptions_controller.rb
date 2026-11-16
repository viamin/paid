# frozen_string_literal: true

module Api
  module V1
    module Projects
      # Bearer-token API parity for the operator staged-closeout surface.
      # @spec STAGED-CLOSEOUT-ADOPTION-001 STAGED-CLOSEOUT-ADOPTION-002 STAGED-CLOSEOUT-ADOPTION-004
      class StagedCloseoutAdoptionsController < BaseController
        before_action -> { require_scope!(:inbox) }
        before_action :set_project

        def show
          authorize @project, :update?
          render json: payload
        end

        def update
          authorize @project, :update?
          StagedCloseoutAdoption::Enroll.call(project: @project, actor: current_user, enabled: params.require(:enabled))
          render json: payload
        rescue StagedCloseoutAdoption::Error => error
          invalid_request(error)
        end

        def create_mapping
          authorize @project, :update?
          issue = @project.issues.find(params.require(:issue_id))
          mapping = StagedCloseoutAdoption::Mappings.approve(
            project: @project, actor: current_user, issue:, attributes: mapping_params
          )
          render json: { mapping: mapping.slice(*mapping_fields) }, status: :created
        rescue StagedCloseoutAdoption::Error, ActiveRecord::RecordInvalid => error
          invalid_request(error)
        end

        def revoke_mapping
          authorize @project, :update?
          mapping = @project.staged_closeout_mappings.find(params[:id])
          record = StagedCloseoutAdoption::Mappings.revoke(
            mapping:, project: @project, actor: current_user, issue: mapping.issue, attributes: {}
          )
          render json: { mapping: record.slice(*mapping_fields) }
        rescue StagedCloseoutAdoption::Error => error
          invalid_request(error)
        end

        private

        def set_project
          @project = policy_scope(Project).find(params[:project_id])
        end

        def payload
          StagedCloseoutAdoption::Projection.for_project(@project)
        end

        def mapping_fields
          StagedCloseoutAdoption::Projection::MAPPING_FIELDS
        end

        def mapping_params
          params.require(:mapping).permit(:criterion_key, :stage, :phase, :target_shape, :execution_path,
            :target_key, :environment_class, :freshness_seconds, retry_policy: {}).to_h
        end
      end
    end
  end
end
