# frozen_string_literal: true

module Interop
  module Connectors
    class Slack < Base
      class << self
        def key
          "slack"
        end

        def display_name
          "Slack"
        end

        def description
          "Connector for ingesting Slack messages and events for notification coexistence and approval workflows."
        end

        def event_types
          %w[message_posted reaction_added channel_joined slash_command interactive].freeze
        end

        def normalize_event(payload)
          {
            "external_id" => payload.dig("event", "ts") || payload["ts"],
            "channel" => payload.dig("event", "channel"),
            "user" => payload.dig("event", "user"),
            "text" => payload.dig("event", "text"),
            "thread_ts" => payload.dig("event", "thread_ts"),
            "event_type" => payload.dig("event", "type"),
            "team" => payload.dig("team", "id")
          }.compact
        end

        def verify_signature?(raw_body, signature:, secret:, request_headers: {})
          return false if secret.blank? || signature.blank?

          timestamp = request_headers["x-slack-request-timestamp"].to_s
          return false if timestamp.blank?

          expected = OpenSSL::HMAC.hexdigest("SHA256", secret, "v0:#{timestamp}:#{raw_body}")
          ActiveSupport::SecurityUtils.secure_compare("v0=#{expected}", signature)
        end
      end
    end
  end
end
