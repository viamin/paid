# frozen_string_literal: true

module Projects
  class ConnectorEventsController < ApplicationController
    before_action :set_project

    def index
      authorize @project, :show?

      events = @project.external_connector_events
        .by_connector(params[:connector_key])
        .by_event_type(params[:event_type])
        .recent
        .limit(50)

      render json: { connector_events: events.as_json(only: %i[id connector_key event_type external_event_id status occurred_at processed_at created_at]) }
    end

    def create
      authorize @project, :update?

      event = Interop::Connectors::IngestEvent.call(
        project: @project,
        connector_key: connector_event_params[:connector_key],
        event_type: connector_event_params[:event_type],
        payload: connector_event_params[:payload] || {},
        external_event_id: connector_event_params[:external_event_id],
        occurred_at: connector_event_params[:occurred_at],
        signature: connector_event_params[:signature],
        secret: connector_secret,
        raw_body: request.raw_post,
        request_headers: signature_headers
      )

      render json: {
        id: event.id,
        connector_key: event.connector_key,
        event_type: event.event_type,
        status: event.status
      }, status: :created
    rescue ActiveRecord::RecordNotUnique
      render json: { errors: [ "Event already processed" ] }, status: :conflict
    rescue ActiveRecord::RecordInvalid, ArgumentError => e
      render json: { errors: [ e.message ] }, status: :unprocessable_content
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def connector_event_params
      params.require(:connector_event).permit(
        :connector_key,
        :event_type,
        :external_event_id,
        :occurred_at,
        :signature,
        payload: {}
      )
    end

    def connector_secret
      credential = @project.account.integration_credentials
        .active
        .for_service(connector_event_params[:connector_key])
        .first

      credential&.secret
    end

    def signature_headers
      request.headers.to_h.slice("X-Slack-Request-Timestamp")
    end
  end
end
