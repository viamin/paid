# frozen_string_literal: true

module Interop
  module Connectors
    class Teams < Base
      class << self
        def key
          "teams"
        end

        def display_name
          "Microsoft Teams"
        end

        def description
          "Connector for ingesting Microsoft Teams events for notification coexistence and approval workflows."
        end

        def event_types
          %w[message_created message_updated adaptive_card_action].freeze
        end

        def normalize_event(payload)
          activity = payload["activity"] || payload
          {
            "external_id" => activity["id"],
            "conversation_id" => activity.dig("conversation", "id"),
            "from" => activity.dig("from", "name"),
            "text" => activity["text"],
            "activity_type" => activity["type"],
            "channel_id" => activity.dig("channelData", "channel", "id"),
            "team_id" => activity.dig("channelData", "team", "id")
          }.compact
        end

        def verify_signature?(raw_body, signature:, secret:, request_headers: {})
          return false if secret.blank? || signature.blank?

          expected = OpenSSL::HMAC.hexdigest("SHA256", secret, raw_body)
          ActiveSupport::SecurityUtils.secure_compare(expected, signature)
        end
      end
    end
  end
end
