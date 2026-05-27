# frozen_string_literal: true

module Interop
  module Connectors
    class GitLab < Base
      class << self
        def key
          "gitlab"
        end

        def display_name
          "GitLab"
        end

        def description
          "Connector for ingesting GitLab merge request and pipeline events for coexistence workflows."
        end

        def event_types
          %w[merge_request_opened merge_request_updated merge_request_merged pipeline_completed push].freeze
        end

        def normalize_event(payload)
          attrs = payload.dig("object_attributes") || {}
          {
            "external_id" => attrs["iid"]&.to_s,
            "title" => attrs["title"],
            "status" => attrs["state"],
            "source_branch" => attrs["source_branch"],
            "target_branch" => attrs["target_branch"],
            "author" => payload.dig("user", "username"),
            "url" => attrs["url"],
            "pipeline_status" => attrs["status"],
            "created_at" => attrs["created_at"],
            "updated_at" => attrs["updated_at"]
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
