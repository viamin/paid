# frozen_string_literal: true

module Api
  class KnowledgeAuditController < ApplicationController
    rescue_from ActiveRecord::RecordNotFound do
      render json: { error: "Project not found" }, status: :not_found
    end

    # GET /api/knowledge/audit?project_id=X&event_type=Y&target_type=Z&target_id=W&since=2026-01-01&page=1
    def index
      @project = Project.find(params[:project_id])
      authorize @project, :show?

      events = KnowledgeAuditEvent.for_project(@project)
      events = events.by_event_type(params[:event_type]) if params[:event_type].present?
      events = events.by_target(params[:target_type], params[:target_id]) if params[:target_type].present? && params[:target_id].present?
      events = events.since(params[:since]) if params[:since].present?

      pagy, records = pagy(events.ordered, limit: params.fetch(:limit, 50).to_i.clamp(1, 200))

      render json: {
        events: records.map { |e| serialize_event(e) },
        pagination: {
          page: pagy.page,
          pages: pagy.pages,
          count: pagy.count,
          limit: pagy.limit
        }
      }
    end

    private

    def serialize_event(event)
      {
        id: event.id,
        event_type: event.event_type,
        actor_type: event.actor_type,
        actor_id: event.actor_id,
        target_type: event.target_type,
        target_id: event.target_id,
        details: event.details,
        created_at: event.created_at.iso8601
      }
    end
  end
end
