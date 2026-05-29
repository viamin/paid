# frozen_string_literal: true

module Api
  module Projects
    class ConnectorEventsController < ActionController::API
      include Api::ProjectInteropAuthentication

      INBOUND_AUTH_KINDS = %w[api_key signing_token].freeze

      SIGNATURE_HEADER_CANDIDATES = {
        "slack" => %w[X-Slack-Signature],
        "jira" => %w[X-Signature X-Hub-Signature X-Hub-Signature-256],
        "linear" => %w[X-Signature X-Hub-Signature X-Hub-Signature-256],
        "teams" => %w[X-Signature X-Hub-Signature X-Hub-Signature-256],
        "gitlab" => %w[X-Gitlab-Token webhook-signature],
        "bitbucket" => %w[X-Signature X-Hub-Signature X-Hub-Signature-256],
        "ci_systems" => %w[X-Signature X-Hub-Signature X-Hub-Signature-256]
      }.freeze

      before_action :set_connector_credential!

      def create
        event = Interop::Connectors::IngestEvent.call(
          project: @project,
          connector_key: connector_event_params[:connector_key],
          event_type: connector_event_params[:event_type],
          payload: raw_payload,
          external_event_id: connector_event_params[:external_event_id],
          occurred_at: connector_event_params[:occurred_at],
          signature: connector_signature,
          secrets: connector_secrets,
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
      rescue ActiveRecord::RecordInvalid => e
        if duplicate_event_error?(e.record)
          render json: { errors: [ "Event already processed" ] }, status: :conflict
        else
          render json: { errors: [ e.message ] }, status: :unprocessable_content
        end
      rescue ArgumentError => e
        render json: { errors: [ e.message ] }, status: :unprocessable_content
      end

      private

      def set_connector_credential!
        return if performed?

        service_key = connector_event_params[:connector_key].to_s
        if service_key.blank?
          render json: { errors: [ "connector_key is required" ] }, status: :unprocessable_content
          return
        end

        @connector_credentials = integration_credentials_for(service_key, auth_kinds: INBOUND_AUTH_KINDS)
        return if @connector_credentials.present?

        render json: { errors: [ "No active integration credential configured for #{service_key.presence || "this connector"}" ] }, status: :unauthorized
      end

      def connector_event_params
        params.require(:connector_event).permit(
          :connector_key,
          :event_type,
          :external_event_id,
          :occurred_at,
          :signature
        )
      end

      def signature_headers
        request.headers.env
          .select { |key, _| key.start_with?("HTTP_") }
          .transform_keys { |key| key.delete_prefix("HTTP_").tr("_", "-") }
      end

      def connector_signature
        signature_header_candidates
          .lazy
          .map { |header| header_value(header).presence }
          .find(&:present?) || connector_event_params[:signature].presence
      end

      def signature_header_candidates
        SIGNATURE_HEADER_CANDIDATES.fetch(connector_event_params[:connector_key].to_s, [])
      end

      def header_value(header_name)
        signature_headers.each do |key, value|
          return value if key.casecmp?(header_name)
        end

        nil
      end

      def connector_secrets
        Array(@connector_credentials).map(&:secret)
      end

      def raw_payload
        payload = params.require(:connector_event).to_unsafe_h["payload"]
        payload.is_a?(Hash) ? payload : {}
      end

      def duplicate_event_error?(record)
        record.is_a?(ExternalConnectorEvent) && record.errors.of_kind?(:external_event_id, :taken)
      end
    end
  end
end
