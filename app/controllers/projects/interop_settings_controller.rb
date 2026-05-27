# frozen_string_literal: true

module Projects
  class InteropSettingsController < ApplicationController
    before_action :set_project

    def update
      authorize @project, :update?

      if @project.update(interop_settings: interop_settings_params.to_h)
        @project.instance_variable_set(:@effective_interop_settings, nil)
        render json: { interop_settings: @project.effective_interop_settings }
      else
        render json: { errors: @project.errors.full_messages }, status: :unprocessable_content
      end
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def interop_settings_params
      params.require(:project).permit(
        :adoption_mode,
        tool_integrations: Interop::Catalog.tool_integration_keys,
        connectors: Interop::Catalog.connector_keys,
        external_execution_sources: Interop::Catalog.external_execution_source_keys,
        imports: [
          :last_import,
          { prompts: %i[source_identifier target_slug] },
          { style_guides: %i[source_identifier target_name] },
          { workflow_policies: %i[source_identifier target_policy_key] }
        ]
      )
    end
  end
end
