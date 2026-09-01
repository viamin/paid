# frozen_string_literal: true

module Projects
  class OkfExportsController < ApplicationController
    before_action :set_project

    def new
      authorize @project, :show?
      @artifact_type_counts = artifact_type_counts
    end

    def create
      authorize @project, :show?

      result = Knowledge::Okf::Export.call(
        project: @project,
        artifact_types: selected_artifact_types,
        actor: { type: "user", id: current_user.id.to_s }
      )
      return render_empty_result if result.files.empty?

      response.headers["X-Okf-Export-Truncated"] = result.truncated_types.join(",") if result.truncated_types.any?
      send_data Knowledge::Okf::BundleArchive.build(result.files),
        filename: "okf-export-#{@project.name.parameterize}-#{Date.current}.tar.gz",
        type: "application/gzip"
    rescue ArgumentError => e
      render_form_error(e.message)
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def okf_export_params
      params.fetch(:okf_export, {}).permit(artifact_types: [])
    end

    def selected_artifact_types
      Array(okf_export_params[:artifact_types]).compact_blank
    end

    def artifact_type_counts
      KnowledgeArtifact.active.for_project(@project)
        .where(artifact_type: Knowledge::Okf::Export::EXPORTABLE_ARTIFACT_TYPES)
        .group(:artifact_type)
        .count
    end

    def render_empty_result
      render_form_error("No exportable knowledge artifacts matched the selected types.")
    end

    def render_form_error(message)
      flash.now[:alert] = message
      @artifact_type_counts = artifact_type_counts
      render :new, status: :unprocessable_content
    end
  end
end
