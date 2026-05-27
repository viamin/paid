# frozen_string_literal: true

module Projects
  class InteroperabilityImportsController < ApplicationController
    before_action :set_project

    def create
      authorize @project, :update?
      Interop::AdoptionModeGuard.enforce!(project: @project, action: :import_config)

      result = Interop::Imports::ApplyProjectPackage.call(
        project: @project,
        source_system: import_params.fetch(:source_system),
        prompts: import_params[:prompts] || [],
        style_guides: import_params[:style_guides] || [],
        workflow_policies: import_params[:workflow_policies] || []
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

    def import_params
      params.require(:interoperability_import).permit(
        :source_system,
        prompts: [
          :slug,
          :name,
          :category,
          :description,
          :template,
          :system_prompt,
          :active,
          { variables: [] }
        ],
        style_guides: %i[name raw_content language active],
        workflow_policies: [
          :policy_key,
          :policy_type,
          :name,
          { context_selector: {} },
          { rules: {} },
          { parameters: {} },
          { metadata: {} }
        ]
      )
    end
  end
end
