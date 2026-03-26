# frozen_string_literal: true

module Api
  class KnowledgeAuditController < ApplicationController
    rescue_from ActiveRecord::RecordNotFound do
      render json: { error: "Project not found" }, status: :not_found
    end

    # GET /api/knowledge/audit?project_id=X&event_type=Y&target_type=Z&target_id=W&since=...&before=...&page=1
    def index
      @project = policy_scope(Project).find(params[:project_id])
      authorize @project, :show?

      events = KnowledgeAuditEvent.for_project(@project)
      events = events.by_event_type(params[:event_type]) if params[:event_type].present?
      if params[:target_type].present? || params[:target_id].present?
        unless params[:target_type].present? && params[:target_id].present?
          return render json: { error: "Both target_type and target_id are required together" }, status: :bad_request
        end

        events = events.by_target(params[:target_type], params[:target_id])
      end

      if params[:since].present?
        since_time = parse_timestamp(params[:since])
        return render json: { error: "Invalid since timestamp" }, status: :bad_request unless since_time

        events = events.since(since_time)
      end

      if params[:before].present?
        before_time = parse_timestamp(params[:before])
        return render json: { error: "Invalid before timestamp" }, status: :bad_request unless before_time

        events = events.before(before_time)
      end

      limit_param = params[:limit]
      if limit_param.present? && limit_param.to_s !~ /\A\d+\z/
        return render json: { error: "limit must be a positive integer" }, status: :bad_request
      end

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

    def parse_timestamp(value)
      Time.zone.parse(value)
    rescue ArgumentError, TypeError
      nil
    end

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
