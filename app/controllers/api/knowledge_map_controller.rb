# frozen_string_literal: true

module Api
  class KnowledgeMapController < ApplicationController
    rescue_from ActiveRecord::RecordNotFound do
      render json: { error: "Project not found" }, status: :not_found
    end

    rescue_from Pundit::NotAuthorizedError do
      render json: { error: "Forbidden" }, status: :forbidden
    end

    # GET /api/knowledge/map?project_id=X
    def show
      @project = TenantContext.with_system_access { Project.find(params[:project_id]) }
      authorize @project, :search?, policy_class: KnowledgeSearchPolicy

      render json: Knowledge::Map::Build.call(project: @project)
    end

    private

    # Override Devise redirect to return JSON 401 for this API endpoint.
    def authenticate_user!
      return if user_signed_in?

      render json: { error: "Unauthorized" }, status: :unauthorized
    end
  end
end
