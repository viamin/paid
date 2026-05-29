# frozen_string_literal: true

module Projects
  class InteroperabilityImportsController < ApplicationController
    before_action :set_project

    def create
      authorize @project, :update?
      Interop::AdoptionModeGuard.enforce!(project: @project, action: :import_config)

      mapped_package = Interop::Imports::MapExternalPackage.call(
        source_system: raw_import_payload.fetch("source_system"),
        raw_data: raw_import_payload.except("source_system")
      )

      result = Interop::Imports::ApplyProjectPackage.call(
        project: @project,
        source_system: mapped_package.source_system,
        prompts: mapped_package.prompts,
        style_guides: mapped_package.style_guides,
        workflow_policies: mapped_package.workflow_policies
      )

      render json: {
        imported: {
          prompts: result.prompts_count,
          style_guides: result.style_guides_count,
          workflow_policies: result.workflow_policies_count
        }
      }, status: :created
    rescue ActiveRecord::RecordInvalid, ArgumentError, KeyError => e
      render json: { errors: [ e.message ] }, status: :unprocessable_content
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def raw_import_payload
      params.require(:interoperability_import).to_unsafe_h.slice(
        "source_system",
        "prompts",
        "style_guides",
        "workflow_policies",
        "workflows",
        "policies"
      )
    end
  end
end
