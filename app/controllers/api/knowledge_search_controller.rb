# frozen_string_literal: true

module Api
  class KnowledgeSearchController < ApplicationController
    skip_after_action :verify_authorized
    skip_after_action :verify_policy_scoped

    rescue_from ActiveRecord::RecordNotFound do
      render json: { error: "Project not found" }, status: :not_found
    end

    # GET /api/knowledge/search?project_id=X&q=...&mode=exact|semantic|hybrid&type=route
    def search
      @project = Project.find(params[:project_id])

      result = Knowledge::Search.call(
        project: @project,
        query: params[:q].to_s,
        mode: params[:mode],
        artifact_type: params[:type],
        limit: params[:limit]
      )

      render json: result
    end
  end
end
