# frozen_string_literal: true

module Projects
  class PdfKnowledgeImportsController < ApplicationController
    before_action :set_project

    def new
      authorize @project, :update?
    end

    def create
      authorize @project, :update?

      result = Knowledge::PdfImports::ImportToProject.call(
        project: @project,
        file: pdf_import_params[:pdf_file],
        actor: current_user
      )

      redirect_to @project,
        notice: "Imported #{result.fetch(:artifact_identifier)} into the project knowledge base."
    rescue Knowledge::PdfImports::ImportError => e
      flash.now[:alert] = e.message
      render :new, status: :unprocessable_content
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def pdf_import_params
      params.fetch(:pdf_import, {}).permit(:pdf_file)
    end
  end
end
