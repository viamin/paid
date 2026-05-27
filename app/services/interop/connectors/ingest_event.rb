# frozen_string_literal: true

module Interop
  module Connectors
    class IngestEvent
      def self.call(...)
        new(...).call
      end

      def initialize(project:, connector_key:, event_type:, payload:, external_event_id:, occurred_at: nil, signature: nil, secret: nil)
        @project = project
        @connector_key = connector_key.to_s
        @event_type = event_type.to_s
        @payload = payload.to_h.deep_stringify_keys
        @external_event_id = external_event_id.to_s
        @occurred_at = occurred_at
        @signature = signature
        @secret = secret
      end

      def call
        validate!

        event = ExternalConnectorEvent.create!(
          project: project,
          account: project.account,
          connector_key: connector_key,
          event_type: event_type,
          external_event_id: external_event_id,
          payload: payload,
          normalized_data: normalized_data,
          occurred_at: occurred_at,
          status: "processed",
          processed_at: Time.current
        )

        Rails.logger.info(
          message: "interop.connector_event_ingested",
          project_id: project.id,
          connector_key: connector_key,
          event_type: event_type,
          external_event_id: external_event_id
        )

        event
      end

      private

      attr_reader :project, :connector_key, :event_type, :payload,
                  :external_event_id, :occurred_at, :signature, :secret

      def validate!
        raise ArgumentError, "connector_key is required" if connector_key.blank?
        raise ArgumentError, "event_type is required" if event_type.blank?
        raise ArgumentError, "external_event_id is required" if external_event_id.blank?

        connector = Connectors::Registry.find(connector_key)
        raise ArgumentError, "unknown connector: #{connector_key}" unless connector

        unless connector_enabled?
          raise ArgumentError, "#{connector_key} connector is not enabled for this project"
        end

        verify_signature!(connector) if signature.present?
      end

      def connector_enabled?
        project.effective_interop_settings
          .fetch("connectors", {})
          .fetch(connector_key, false) == true
      end

      def verify_signature!(connector)
        unless connector.verify_signature?(payload, signature: signature, secret: secret)
          raise ArgumentError, "signature verification failed for #{connector_key}"
        end
      end

      def normalized_data
        connector = Connectors::Registry.find(connector_key)
        return {} unless connector

        connector.normalize_event(payload)
      rescue StandardError => e
        Rails.logger.warn(
          message: "interop.connector_normalization_failed",
          connector_key: connector_key,
          error: e.message
        )
        {}
      end
    end
  end
end
