# frozen_string_literal: true

module Api
  class KnowledgeSearchController < ApplicationController
    RATE_LIMIT_MAX_REQUESTS = 60
    RATE_LIMIT_PERIOD = 1.minute

    # Uses Rails 8 built-in rate_limit (ActionController::RateLimiting)
    rate_limit to: RATE_LIMIT_MAX_REQUESTS, within: RATE_LIMIT_PERIOD,
      by: -> { current_user&.id },
      with: -> { render json: { error: "Rate limit exceeded" }, status: :too_many_requests }

    rescue_from ActiveRecord::RecordNotFound do
      render json: { error: "Project not found" }, status: :not_found
    end

    rescue_from Pundit::NotAuthorizedError do
      render json: { error: "Forbidden" }, status: :forbidden
    end

    # GET /api/knowledge/search?project_id=X&q=...&mode=exact|semantic|hybrid&type=route&version=abc123&limit=20
    def search
      @project = Project.find(params[:project_id])
      authorize @project, :search?, policy_class: KnowledgeSearchPolicy

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

    private

    # Override Devise redirect to return JSON 401 for this API endpoint.
    def authenticate_user!
      return if user_signed_in?

      render json: { error: "Unauthorized" }, status: :unauthorized
    end
  end
end
