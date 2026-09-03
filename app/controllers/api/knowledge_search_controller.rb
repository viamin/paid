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

    rescue_from Knowledge::Uri::InvalidUriError do |e|
      render json: { error: e.message }, status: :bad_request
    end

    # GET /api/knowledge/search?project_id=X&q=...&mode=exact|semantic|hybrid&type=route&version=abc123&limit=20
    def search
      @project = TenantContext.with_system_access { Project.find(params[:project_id]) }
      authorize @project, :search?, policy_class: KnowledgeSearchPolicy

      mode = params[:mode]

      if mode != "exact" && !@project.semantic_search_available?
        # When no semantic embedding provider is available, only exact search is available.
        mode = "exact"
      end

      result = Knowledge::Search.call(
        project: @project,
        query: params[:q].to_s,
        mode: mode,
        artifact_type: params[:type],
        version: params[:version],
        limit: params[:limit]
      )

      render json: result
    end

    # GET /api/knowledge/resolve?uri=paidkb://project/123/chunk/<uuid>
    #
    # @spec KNOWLEDGE-URI-002
    def resolve
      parsed = Knowledge::Uri.parse(params[:uri].to_s)
      @project = TenantContext.with_system_access { Project.find(parsed.project_id) }
      authorize @project, :search?, policy_class: KnowledgeSearchPolicy

      record = Knowledge::Uri::Resolver.call(parsed, project: @project)
      return render json: { error: "Not found" }, status: :not_found unless record

      render json: serialize_resolved(record, parsed:)
    end

    private

    def serialize_resolved(record, parsed:)
      case record
      when KnowledgeChunk
        {
          kind: "chunk", uri: record.knowledge_uri, chunk_id: record.id,
          artifact_id: record.knowledge_artifact_id, artifact_type: record.knowledge_artifact.artifact_type,
          content: record.content, status: record.status
        }
      when KnowledgeArtifact
        {
          kind: "artifact", uri: record.knowledge_uri(commit_sha: parsed.commit_sha), artifact_id: record.id,
          artifact_type: record.artifact_type, identifier: record.identifier,
          scope_path: record.scope_path, status: record.status
        }
      end
    end

    # Override Devise redirect to return JSON 401 for this API endpoint.
    def authenticate_user!
      return if user_signed_in?

      render json: { error: "Unauthorized" }, status: :unauthorized
    end
  end
end
