# frozen_string_literal: true

module Api
  class KnowledgeSearchController < ApplicationController
    rescue_from ActiveRecord::RecordNotFound do
      render json: { error: "Project not found" }, status: :not_found
    end

    # GET /api/knowledge/search?project_id=X&q=...&mode=exact|semantic|hybrid&type=route&version=abc123&limit=20
    def search
      @project = Project.find(params[:project_id])
      authorize @project, :show?

      result = Knowledge::Search.call(
        project: @project,
        query: params[:q].to_s,
        mode: params[:mode],
        artifact_type: params[:type],
        version: params[:version],
        limit: params[:limit]
      )

      render json: result
    end
  end
end
