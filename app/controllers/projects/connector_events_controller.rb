# frozen_string_literal: true

module Projects
  class ConnectorEventsController < ApplicationController
    before_action :set_project

    def index
      authorize @project, :show?

      events = @project.external_connector_events
      events = events.by_connector(params[:connector_key]) if params[:connector_key].present?
      events = events.by_event_type(params[:event_type]) if params[:event_type].present?
      events = events.recent.limit(50)

      render json: { connector_events: events.as_json(only: %i[id connector_key event_type external_event_id status occurred_at processed_at created_at]) }
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end
  end
end
