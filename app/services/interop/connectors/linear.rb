# frozen_string_literal: true

module Interop
  module Connectors
    class Linear < Base
      class << self
        def key
          "linear"
        end

        def display_name
          "Linear"
        end

        def description
          "Connector for ingesting Linear issue events for coexistence with Paid issue management."
        end

        def event_types
          %w[issue_created issue_updated issue_commented issue_state_changed issue_deleted].freeze
        end

        def normalize_event(payload)
          data = payload["data"] || {}
          {
            "external_id" => data["identifier"],
            "title" => data["title"],
            "status" => data.dig("state", "name"),
            "priority" => data["priorityLabel"],
            "assignee" => data.dig("assignee", "displayName"),
            "labels" => Array(data.dig("labels")).map { |l| l["name"] },
            "team_key" => data.dig("team", "key"),
            "created_at" => data["createdAt"],
            "updated_at" => data["updatedAt"]
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
