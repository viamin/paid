# frozen_string_literal: true

module Projects
  class ConnectorEventsController < ApplicationController
    SIGNATURE_HEADER_CANDIDATES = {
      "slack" => %w[X-Slack-Signature],
      "jira" => %w[X-Signature X-Hub-Signature X-Hub-Signature-256],
      "linear" => %w[X-Signature X-Hub-Signature X-Hub-Signature-256],
      "teams" => %w[X-Signature X-Hub-Signature X-Hub-Signature-256],
      "gitlab" => %w[X-Signature X-Hub-Signature X-Hub-Signature-256],
      "bitbucket" => %w[X-Signature X-Hub-Signature X-Hub-Signature-256],
      "ci_systems" => %w[X-Signature X-Hub-Signature X-Hub-Signature-256]
    }.freeze

    before_action :set_project

    def index
      authorize @project, :show?

      events = @project.external_connector_events
      events = events.by_connector(params[:connector_key]) if params[:connector_key].present?
      events = events.by_event_type(params[:event_type]) if params[:event_type].present?
      events = events.recent.limit(50)

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
        signature: connector_signature,
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
      request.headers.env
        .select { |key, _| key.start_with?("HTTP_X_") }
        .transform_keys { |key| key.delete_prefix("HTTP_").tr("_", "-") }
    end

    def connector_signature
      signature_header_candidates
        .lazy
        .map { |header| request.headers[header].presence }
        .find(&:present?) || connector_event_params[:signature].presence
    end

    def signature_header_candidates
      SIGNATURE_HEADER_CANDIDATES.fetch(connector_event_params[:connector_key].to_s, [])
    end
  end
end
