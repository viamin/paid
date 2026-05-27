# frozen_string_literal: true

module Interop
  module Connectors
    class Jira < Base
      class << self
        def key
          "jira"
        end

        def display_name
          "Jira"
        end

        def description
          "Connector for ingesting Jira issue events for coexistence with Paid issue management."
        end

        def event_types
          %w[issue_created issue_updated issue_commented issue_transitioned issue_deleted].freeze
        end

        def normalize_event(payload)
          fields = payload.dig("issue", "fields") || {}
          {
            "external_id" => payload.dig("issue", "key"),
            "title" => fields.dig("summary"),
            "status" => fields.dig("status", "name"),
            "priority" => fields.dig("priority", "name"),
            "assignee" => fields.dig("assignee", "displayName"),
            "labels" => fields["labels"],
            "issue_type" => fields.dig("issuetype", "name"),
            "project_key" => fields.dig("project", "key"),
            "created_at" => fields["created"],
            "updated_at" => fields["updated"]
          }.compact
        end

        def verify_signature?(payload, signature:, secret:)
          return false if secret.blank? || signature.blank?

          expected = OpenSSL::HMAC.hexdigest("SHA256", secret, payload.to_json)
          ActiveSupport::SecurityUtils.secure_compare(expected, signature)
        end
      end
    end
  end
end
